require "rails_helper"

# ADR 0039, Invariantes, provados de ponta a ponta: UBS nunca gera BPA;
# crítica nunca impede o registro; arquivo gerado nunca é alterado
# (reabertura gera versão nova); arquivo e dado de paciente nunca em log nem
# em evento; download sempre na trilha; re-cifra só toca o texto cifrado;
# Data/Struct com dado pessoal nunca mostra o valor.
RSpec.describe "Invariantes do faturamento (ADR 0039)", type: :request do
  before do
    billing_city!
    billing_settings!
  end

  let(:upa) { upa! }
  let(:ubs) { create_unit("UBS #{SecureRandom.hex(2)}").tap { |unit| unit.update!(cnes: billing_cnes) } }
  let(:doctor) { doctor!(upa).tap { |user| link_professional!(user, ubs, cbo: "225125") } }
  let(:clerk) { billing_clerk! }
  let(:patient) { billing_patient! }
  let(:app_files) do
    Dir[Rails.root.join("app/{commands,services,controllers,jobs}/**/billing/**/*.rb")] +
      Dir[Rails.root.join("app/services/timeline/sources/procedure_source.rb")]
  end
  let(:publish_files) do
    (app_files + %w[app/controllers/attendance_controller.rb app/controllers/check_ins_controller.rb
                    app/services/patients/demographics.rb app/controllers/billing/patients_controller.rb]
      .map { |path| Rails.root.join(path).to_s }).uniq.select { |f| File.exist?(f) }
  end

  def rolled_back = ApplicationRecord.transaction(requires_new: true) do
    yield
    raise ActiveRecord::Rollback
  end

  # Corpo inteiro (multilinha) das chamadas `opening`...`)`, por balanceamento de parênteses.
  def balanced_calls(opening, files)
    files.flat_map do |file|
      src = File.read(file)
      src.enum_for(:scan, opening).map do
        i = start = Regexp.last_match.end(0)
        depth = 1
        while depth.positive? && i < src.length
          depth += 1 if src[i] == "("
          depth -= 1 if src[i] == ")"
          i += 1
        end
        [ file, src[start...(i - 1)] ]
      end
    end
  end

  # Divide nas vírgulas de nível zero.
  def top_level_args(body)
    args = [ +"" ]
    depth = 0
    body.each_char do |c|
      depth += 1 if "([{".include?(c)
      depth -= 1 if ")]}".include?(c)
      if c == "," && depth.zero?
        args << +""
      else
        args.last << c
      end
    end
    args.map(&:strip).reject(&:empty?)
  end

  def code_lines(path) = File.readlines(path).reject { |l| l.strip.start_with?("#") }.join

  def publish_calls = balanced_calls(/DomainEvents\.publish\(/, publish_files)

  it "UBS nunca gera BPA: grava (201) com establishment_is_aps, sem competência; o arquivo da UPA não leva a UBS" do
    sign_in_as(doctor)
    json_post "/billing/procedures", patient_id: patient.id, establishment: { type: "health_unit", id: ubs.id }, performed_on: Time.zone.today.iso8601,
                                     sigtap_code: "0301060029", quantity: 1, cid10: "I10"
    expect(response).to have_http_status(:created)
    expect(json_body).to include("billable" => false, "blocking_reasons" => %w[establishment_is_aps], "billing_competence" => nil)
    expect(BillingPeriod.where(health_unit_id: ubs.id)).to be_empty
    upa_procedure = recorded_procedure!(unit: upa, professional: doctor, patient: patient)
    export = Billing::Close.call(period: upa_procedure.billing_period, by: clerk).payload[:export]
    expect(export.bytes.split("\r\n").drop(1).map { |line| line[2, 7] }.uniq).to eq([ upa.cnes ])
    expect(export.bytes).not_to include(ubs.cnes)
  end

  it "crítica nunca impede: cada motivo grava 201" do
    sign_in_as(doctor)
    [ { cid10: nil }, { cid10: "N390" }, { sigtap_code: "0399999999" }, { sigtap_code: "0604320124", cid10: nil } ].each do |over|
      json_post "/billing/procedures", { patient_id: patient.id, establishment: { type: "health_unit", id: upa.id },
                                         performed_on: Time.zone.today.iso8601, sigtap_code: "0301060029", quantity: 1, cid10: "I10" }.merge(over)
      expect(response).to have_http_status(:created), over.inspect
      expect(json_body["billable"]).to be(false)
    end
  end

  it "arquivo nunca alterado: reabrir e fechar gera versão 2; a 1 continua igual e baixável" do
    procedure = recorded_procedure!(unit: upa, professional: doctor, patient: patient)
    period = procedure.billing_period
    v1 = Billing::Close.call(period: period, by: clerk).payload[:export]
    bytes = v1.bytes
    Billing::Reopen.call(period: period, reason: "Correção do CNS do médico", by: clerk)
    v2 = Billing::Close.call(period: period.reload, by: clerk).payload[:export]
    expect(v2.version).to eq(2)
    expect(v1.reload.bytes).to eq(bytes)
    expect { v1.update!(sha256: "f" * 64) }.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
    sign_in_as(clerk)
    get "/billing/exports/#{v1.id}/file"
    expect(response.body.b).to eq(bytes)
    expect(DomainEvent.where(name: "billing_export.downloaded").count).to eq(1)
  end

  describe "re-cifra (CityEncryption.allowing_reencryption)" do
    it "procedimento cancelado, export e competência reaberta recifram; coluna clínica continua recusada sob a marca" do
      cancelled = recorded_procedure!(unit: upa, professional: doctor, patient: patient)
      Billing::Cancel.call(procedure: cancelled, reason: "Lançado no paciente errado", by: doctor)
      cancelled.reload
      kept = recorded_procedure!(unit: upa, professional: doctor, patient: patient)
      period = kept.billing_period
      export = Billing::Close.call(period: period, by: clerk).payload[:export]
      Billing::Reopen.call(period: period.reload, reason: "Correção do CNS do médico", by: clerk)
      period.reload
      export.reload
      before = [ cancelled, export, period ].map { |r| r.attributes_before_type_cast.slice("cancel_reason", "file", "reopened_reason").values.compact }

      rolled_back do
        CityEncryption.allowing_reencryption do
          cancelled.encrypt
          export.encrypt
          period.encrypt
        end
        expect(cancelled.reload.cancel_reason).to eq("Lançado no paciente errado")
        expect(export.reload.bytes).to start_with("01#BPA#")
        expect(period.reload.reopened_reason).to eq("Correção do CNS do médico")
        after = [ cancelled, export, period ].map { |r| r.attributes_before_type_cast.slice("cancel_reason", "file", "reopened_reason").values.compact }
        expect(after).not_to eq(before)
      end

      expect { rolled_back { CityEncryption.allowing_reencryption { cancelled.update_columns(quantity: 2) } } }
        .to raise_error(ActiveRecord::StatementInvalid)
      expect { rolled_back { CityEncryption.allowing_reencryption { export.update_columns(sha256: "f" * 64) } } }
        .to raise_error(ActiveRecord::StatementInvalid)
      expect { rolled_back { CityEncryption.allowing_reencryption { kept.update_columns(quantity: 2) } } }
        .to raise_error(ActiveRecord::StatementInvalid)
    end
  end

  describe "eventos do faturamento" do
    it "em tempo de execução: só ids e os campos do contrato" do
      allowed = %w[performed_procedure_id billing_period_id billing_export_id billing_setting_id patient_id user_id source billable version procedure_ids]
      procedure = recorded_procedure!(unit: upa, professional: doctor, patient: patient)
      Billing::Close.call(period: procedure.billing_period, by: clerk)
      payload_keys = DomainEvent.where("name LIKE 'billing%' OR name LIKE 'performed_procedure%'").flat_map { |event| event.payload.keys }
      expect(payload_keys).not_to be_empty
      expect(payload_keys - allowed).to eq([])
    end

    let(:calls) do
      publish_calls.select { |_f, body| body =~ /\A\s*"(billing|performed_procedure|patient\.demographics)/ }
                   .map { |file, body| args = top_level_args(body); [ file, args.first[/"([^"]+)"/, 1], args.drop(1) ] }
    end

    it "a varredura de fonte encontra os eventos do faturamento (não está vazia)" do
      expect(calls.map { |_f, name, _p| name }.uniq).to match_array(
        %w[performed_procedure.recorded performed_procedure.cancelled billing_period.closed billing_period.reopened
           billing_period.pending_viewed billing_export.generated billing_export.downloaded billing_settings.changed
           billing_patient.looked_up billing_patient.demographics_updated patient.demographics_updated billing_procedures.listed]
      )
    end

    it "todo nome publicado está declarado no initializer e na spec de bindings" do
      declared = code_lines(Rails.root.join("config/initializers/domain_events.rb"))
      bindings = code_lines(Rails.root.join("spec/initializers/domain_events_bindings_spec.rb"))
      calls.map { |_f, name, _p| name }.uniq.each do |name|
        expect(declared).to match(/%w\[[^\]]*(?<![\w.])#{Regexp.escape(name)}(?![\w.])[^\]]*\]/), "evento #{name} sem bind no initializer"
        expect(bindings).to match(/(?<![\w.])#{Regexp.escape(name)}(?![\w.])/), "evento #{name} fora da spec de bindings"
      end
    end

    it "o payload é literal (chave: valor) só com ids e os campos do contrato, sem dado pessoal" do
      allowed_extra = %w[source billable version procedure_ids]
      calls.each do |file, name, args|
        expect(args).not_to be_empty, "#{name} (#{file}) sem payload"
        args.each do |arg|
          key = arg[/\A([a-z_]+):\s/, 1]
          expect(key).not_to be_nil, "#{name} (#{file}) tem payload não literal: #{arg}"
          expect(key.end_with?("_id") || allowed_extra.include?(key)).to be(true), "#{name} (#{file}) publica #{key}"
        end
      end
      publish_calls.each do |file, call|
        expect(call).not_to match(/\b(cpf|cns|full_name|birth_date|file|bytes|reason|cancel_reason|reopened_reason|phone)\b/), "#{file}: #{call}"
      end
    end

    it "a varredura recusa payload não literal (variável ou splat)" do
      expect(top_level_args(%("x.y", **payload)).drop(1).map { |a| a[/\A([a-z_]+):\s/, 1] }).to eq([ nil ])
      expect(top_level_args(%("x.y", payload)).drop(1).map { |a| a[/\A([a-z_]+):\s/, 1] }).to eq([ nil ])
    end
  end

  it "nenhum log no código do faturamento e nenhum inspect com conteúdo" do
    app_files.each { |file| expect(File.read(file)).not_to match(/Rails\.logger|puts |\bp\(/), file }
    procedure = recorded_procedure!(unit: upa, professional: doctor, patient: patient)
    export = Billing::Close.call(period: procedure.billing_period, by: clerk).payload[:export]
    expect([ export.inspect, procedure.inspect, procedure.billing_period.inspect ].join).not_to include(patient.cpf, "#BPA#")
  end

  it "arquivo, CPF, nome e motivo ficam fora do log e dos eventos ao longo do fluxo" do
    reason = "MOTIVO-#{SecureRandom.hex(4)}-confidencial"
    log = capture_log do
      procedure = recorded_procedure!(unit: upa, professional: doctor, patient: patient)
      other = recorded_procedure!(unit: upa, professional: doctor, patient: patient)
      Billing::Cancel.call(procedure: other, reason: reason, by: doctor)
      export = Billing::Close.call(period: procedure.billing_period, by: clerk).payload[:export]
      Billing::Reopen.call(period: procedure.billing_period.reload, reason: reason, by: clerk)
      sign_in_as(clerk)
      get "/billing/exports/#{export.id}/file"
      @bytes = export.bytes
    end
    payloads = DomainEvent.where("name LIKE 'billing%' OR name LIKE 'performed_procedure%'").pluck(:payload).to_json
    expect(DomainEvent.where(name: "billing_export.downloaded")).to exist
    [ patient.cpf, patient.full_name, reason, "#BPA#", @bytes.lines.second.to_s.strip ].reject(&:blank?).each do |secret|
      expect(log).not_to include(secret)
      expect(payloads).not_to include(secret)
    end
  end

  describe "Data/Struct com dado pessoal" do
    def shows_nothing_of(object, secrets)
      outputs = [ object.inspect, object.to_s, "#{object}", PP.pp(object, +"") ]
      secrets.each { |secret| outputs.each { |out| expect(out).not_to include(secret.to_s) } }
    end

    it "ILine, Built, Facts e Contact não mostram CPF, CNS, nome, endereço, telefone nem o arquivo" do
      line = Billing::BpaFile::ILine.new(key: "k1", cnes: "1234567", competence: "202610", professional_cns: "700000000000001", cbo: "225125",
                                         performed_on: Date.current, procedure: "0301060029", sex: "F", ibge: "410690", cid10: "I10", age: 33,
                                         quantity: 1, character: "01", name: "MARIA SEGREDO DA SILVA", birth_date: Date.new(1990, 1, 2),
                                         race_color: "03", ethnicity: nil, zip: "80010000", street: "RUA SECRETA", number: "9988",
                                         complement: "APTO 77", district: "BAIRRO SECRETO", phone: "41999887766", cpf: "52998224725")
      shows_nothing_of(line, %w[MARIA SEGREDO RUA\ SECRETA 9988 APTO BAIRRO 41999887766 52998224725 700000000000001 80010000 19900102])

      built = Billing::BpaFile::Built.new(bytes: "01#BPA#202610CONTEUDO-SECRETO".b, control: 1234, lines_bpa_c: 1, lines_bpa_i: 2, sheets: 1)
      shows_nothing_of(built, %w[#BPA# CONTEUDO-SECRETO])

      facts = Billing::Critic::Facts.new(establishment: Billing::Establishment.for_unit(upa), sigtap_code: "0301060029", performed_on: Date.current,
                                         cbo_code: "225125", professional_cns: "700000000000001", cid10: "I10", patient: patient)
      shows_nothing_of(facts, [ "700000000000001", patient.cpf, patient.full_name, upa.cnes ])

      contact = Billing::PatientContact::Contact.new(district: "BAIRRO SECRETO", phone: "41999887766")
      shows_nothing_of(contact, %w[SECRETO 41999887766])
    end
  end
end
