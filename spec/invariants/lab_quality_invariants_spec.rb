require "rails_helper"

# ADR 0038, Invariantes, provados de ponta a ponta: cada um tenta a escrita
# proibida e espera a recusa do banco ou da aplicação; valor de controle,
# justificativa e código de barras fora de log e de evento.
RSpec.describe "Invariantes da qualidade e dos insumos (ADR 0038)", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  before { qc_city!(inventory: true, hl7: true) }

  let(:s) { qc_scenario! }
  let(:staff) { lab_staff! }
  let(:lead) { lab_releaser!(s.provider, lead: true) }
  let(:conn) { ApplicationRecord.connection }

  def rolled_back = ApplicationRecord.transaction(requires_new: true) do
    yield
    raise ActiveRecord::Rollback
  end

  def refused(pattern, &block)
    expect { rolled_back(&block) }.to raise_error(ActiveRecord::StatementInvalid, pattern)
  end

  def release!(req, item) = Lab::Release.call(requisition: req, item_ids: [ item.id ], signature: "advanced", totp: totp_for(lead), by: lead)

  # Bloqueio ativo com um item digitado, uma exceção, uma revisão pendente,
  # uma rodada e um relatório do CEQ e um lote em uso.
  def world!
    qc_value!(s, "Nível 1", 3.6, by: staff)
    block = LabQcBlock.active.sole
    req = received_requisition!(provider: s.provider, exams: [ s.exam ])
    item = type!(req.items.first, { glicose: "98" })
    exception = Lab::Qc::GrantException.call(block_id: block.id, item_id: item.id, justification: "Paciente em sala de parto", by: lead).payload[:exception]
    review = LabQcReviewItem.create!(lab_qc_block: block, lab_requisition_item_id: item.id)
    round = LabEqaRound.create!(exam_provider: s.provider, program: "PNCQ", round_code: "R1", round_date: Time.zone.today, recorded_by_user: lead,
                                items: [ { analyte_key: "glicose", adequacy: "adequate" } ])
    report = LabEqaAnnualReport.create!(exam_provider: s.provider, program: "PNCQ", year: 2026, recorded_by_user: lead,
                                        file: pdf_file!(user: lead, provider: s.provider), created_at: Time.current)
    supply = LabSupply.create!(exam_provider: s.provider, name: "Glicose", kind: "reagent", unit: "kit", tests_per_package: 100, minimum_stock: 1,
                               expiry_alert_days: 30, lab_exam_ids: [ s.exam.id ])
    lot = Lab::Inventory::ReceiveLot.call({ "supply_id" => supply.id, "lot_number" => "L1", "expires_on" => (Time.zone.today + 90).iso8601,
                                            "supplier" => "D", "origin" => "donation", "quantity" => 3 }, by: staff).payload[:lot]
    Lab::Inventory::SetInUse.call(lot_id: lot.id, instrument_id: s.instrument.id, lab_exam_id: s.exam.id, by: staff)
    in_use = LabSupplyInUse.sole
    { block: block, item: item, exception: exception, review: review, round: round, report: report, supply: supply, lot: lot, in_use: in_use }
  end

  it "valor de controle nunca vira resultado de paciente (digitado ou pela HL7)" do
    qc_value!(s, "Nível 1", 0.3, by: staff)
    body = "MSH|^~\\&|MW|LAB|ROTA-SAUDE|t|20261018073000||OUL^R22^OUL_R22|INV1|P|2.5.1\rSPM|1|#{s.lot.barcodes.first.barcode}|||||||||Q\r" \
           "OBR|1|||GLI^G^99RSL\rOBX|1|NM|glicose^G^99RSL||101.5|mg/dL|||||F|||20261018072500||||BIO-01\r"
    log = capture_log { hl7_post(body, token: middleware_token!(s.provider)) }
    expect(LabQcValue.count).to eq(2)
    expect([ LabResult.count, ExamResult.count ]).to eq([ 0, 0 ])
    expect(log).not_to include("101.5", s.lot.barcodes.first.barcode)
  end

  it "com bloqueio ativo, só exceção do RT libera; a exceção fica registrada" do
    qc_value!(s, "Nível 1", 3.6, by: staff)
    req = received_requisition!(provider: s.provider, exams: [ s.exam ])
    item = type!(req.items.first, { glicose: "98" })
    refused = release!(req, item)
    expect(refused.reason).to eq(:qc_blocked)
    Lab::Qc::GrantException.call(block_id: LabQcBlock.active.sole.id, item_id: item.id, justification: "Paciente em sala de parto", by: lead)
    travel 31.seconds do
      expect(release!(req, item)).to be_ok
    end
    expect(LabQcException.sole.justification).to eq("Paciente em sala de parto")
    expect(DomainEvent.where("name LIKE 'lab_%'").pluck(:payload).to_json).not_to include("sala de parto")
  end

  it "corridas, valores, referências, exceções, revisões e movimentos nunca mudam nem somem" do
    qc_value!(s, "Nível 1", 3.6, by: staff)
    [ LabQcRun.first, LabQcValue.first, LabQcTarget.first ].each do |row|
      expect { row.destroy! }.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
    end
    expect { LabQcValue.first.update!(outcome: "ok") }.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
    expect { LabQcRun.first.update!(status: "approved") }.to raise_error(ActiveRecord::StatementInvalid, /refused/)
    expect { ActiveRecord::Base.connection.execute("TRUNCATE lab_qc_values") }.to raise_error(ActiveRecord::StatementInvalid)
  end

  it "saldo de lote nunca negativo e resultado guarda o lote em uso (ou nada)" do
    supply = LabSupply.create!(exam_provider: s.provider, name: "Glicose", kind: "reagent", unit: "kit", tests_per_package: 100, minimum_stock: 1,
                               expiry_alert_days: 30, lab_exam_ids: [ s.exam.id ])
    lot = Lab::Inventory::ReceiveLot.call({ "supply_id" => supply.id, "lot_number" => "L1", "expires_on" => (Time.zone.today + 90).iso8601,
                                            "supplier" => "D", "origin" => "donation", "quantity" => 1 }, by: staff).payload[:lot]
    expect(Lab::Inventory::RecordMovement.call(lot: lot, kind: "loss", quantity: 2, reason: "Quebra", by: staff, admin: false).reason)
      .to eq(:insufficient_balance)
    expect(lot.balance).to eq(1)
    req = received_requisition!(provider: s.provider, exams: [ s.exam ])
    expect(type!(req.items.first, { glicose: "98" }).results.last.reagent_lot_id).to be_nil
    Lab::Inventory::SetInUse.call(lot_id: lot.id, instrument_id: s.instrument.id, lab_exam_id: s.exam.id, by: staff)
    expect(type!(req.items.first, { glicose: "97" }).results.last.reagent_lot_id).to eq(lot.id)
  end

  it "saldo negativo é recusado também pelo banco (cinto de segurança)" do
    w = world!
    refused(/negative balance refused/) do
      LabSupplyMovement.create!(lab_supply_lot_id: w[:lot].id, kind: "loss", quantity: -99, reason: "Quebra", recorded_by_user: staff, recorded_at: Time.current, created_at: Time.current)
    end
  end

  context "com o mundo montado" do
    let!(:w) { world! }

    it "rodada e relatório anual do CEQ são só acréscimo (UPDATE e DELETE recusados)" do
      refused(/lab_eqa_rounds is append-only: UPDATE refused/) { w[:round].update!(program: "OUTRO") }
      refused(/lab_eqa_rounds is append-only: DELETE refused/) { w[:round].destroy! }
      refused(/lab_eqa_annual_reports is append-only: UPDATE refused/) { w[:report].update!(program: "OUTRO") }
      refused(/lab_eqa_annual_reports is append-only: DELETE refused/) { w[:report].destroy! }
    end

    it "aparelho, material e item de estoque nunca são apagados" do
      refused(/lab_instruments is append-only: DELETE refused/) { s.instrument.destroy! }
      refused(/lab_qc_materials is append-only: DELETE refused/) { s.material.destroy! }
      refused(/lab_supplies is append-only: DELETE refused/) { w[:supply].destroy! }
    end

    it "valor, referência, código de barras, regra e lote de estoque só crescem; movimento também" do
      refused(/lab_qc_values is append-only: DELETE refused/) { LabQcValue.first.destroy! }
      refused(/lab_qc_targets is append-only: DELETE refused/) { LabQcTarget.first.destroy! }
      refused(/lab_qc_lot_barcodes is append-only: UPDATE refused/) { LabQcLotBarcode.first.update!(level: "Nível 9") }
      refused(/lab_qc_lot_barcodes is append-only: DELETE refused/) { LabQcLotBarcode.first.destroy! }
      refused(/lab_supply_lots is append-only: UPDATE refused/) { w[:lot].update!(lot_number: "L2") }
      refused(/lab_supply_lots is append-only: DELETE refused/) { w[:lot].destroy! }
      refused(/lab_supply_movements is append-only: DELETE refused/) { LabSupplyMovement.first.destroy! }
      refused(/lab_supply_movements is append-only: UPDATE refused/) { LabSupplyMovement.first.update!(reason: "Outro") }
    end

    it "exceção, revisão e lote em uso: DELETE recusado; UPDATE comum recusado" do
      refused(/lab_qc_exceptions is append-only: DELETE refused/) { w[:exception].destroy! }
      refused(/lab_qc_exceptions is append-only: UPDATE refused/) { w[:exception].update!(justification: "Outra") }
      refused(/lab_qc_review_items is append-only: DELETE refused/) { w[:review].destroy! }
      refused(/a review is decided once/) { w[:review].update!(note: "Outra nota") }
      refused(/lab_supply_in_use is append-only: DELETE refused/) { w[:in_use].destroy! }
      refused(/a lot in use only ends, once/) { w[:in_use].update_columns(lab_exam_id: SecureRandom.uuid) }
    end

    it "lote de controle só encerra; bloqueio fecha uma vez e só com ação; corrida nunca melhora" do
      refused(/lab_qc_lots is append-only: DELETE refused/) { s.lot.destroy! }
      refused(/only in_use -> closed is allowed/) { s.lot.update!(expires_on: Time.zone.today + 400) }
      refused(/lab_qc_blocks is append-only: DELETE refused/) { w[:block].destroy! }
      refused(/one corrective action, closed once and only with it/) { w[:block].update!(closed_at: Time.current) }
      refused(/status rejected -> approved refused/) { LabQcRun.first.update!(status: "approved") }
    end

    it "TRUNCATE recusado em toda tabela só-acréscimo do 21c" do
      tables = %w[lab_instruments lab_qc_materials lab_qc_lots lab_qc_lot_barcodes lab_qc_targets lab_qc_runs lab_qc_values lab_qc_rules
                  lab_qc_blocks lab_qc_exceptions lab_qc_review_items lab_eqa_rounds lab_eqa_annual_reports lab_supplies lab_supply_lots
                  lab_supply_movements lab_supply_in_use]
      tables.each do |table|
        refused(/#{table} is append-only: TRUNCATE refused/) { conn.execute("TRUNCATE #{table} CASCADE") }
      end
    end

    # Mutação: tirar o ramo rota.reencrypting de rota_lab_qc_review_guard ou a lista de
    # colunas do *_reencryption_only da exceção (re-cifra recusada); comparar a linha toda
    # menos a coluna cifrada (outra coluna aceita sob a marca).
    it "re-cifra da nota da revisão e da justificativa da exceção: aceita sem tocar updated_at; update comum recusado" do
      review = w[:review]
      Lab::Qc::DecideReview.call(review: review, decision: "kept", note: "Nota confidencial do RT", by: lead)
      review.reload
      exception = w[:exception].reload
      stamps = [ review.updated_at, exception.created_at ]
      before = [ review.read_attribute_before_type_cast("note"), exception.read_attribute_before_type_cast("justification") ]

      rolled_back do
        CityEncryption.allowing_reencryption do
          review.encrypt
          exception.encrypt
        end
        expect(review.reload.updated_at).to eq(stamps.first)
        expect([ review.note, exception.reload.justification ]).to eq([ "Nota confidencial do RT", "Paciente em sala de parto" ])
        expect([ review.read_attribute_before_type_cast("note"), exception.read_attribute_before_type_cast("justification") ]).not_to eq(before)
      end

      refused(/a review is decided once/) { review.update!(note: "Outra") }
      refused(/lab_qc_exceptions is append-only: UPDATE refused/) { exception.update!(justification: "Outra") }
      # sob a marca, outra coluna continua proibida
      refused(/a review is decided once/) { CityEncryption.allowing_reencryption { review.update_columns(decision: "rectify") } }
      refused(/lab_qc_exceptions is append-only: UPDATE refused/) do
        CityEncryption.allowing_reencryption { exception.update_columns(lab_requisition_item_id: SecureRandom.uuid) }
      end
    end
  end

  # Varredura: nada de valor, justificativa, nota, ação corretiva ou código de
  # barras em log nem em payload de evento, ao longo dos comandos do 21c.
  it "valor, justificativa, nota, ação corretiva e código de barras ficam fora de log e de eventos" do
    marker_value = "103.1234"
    note = "NOTA-#{SecureRandom.hex(4)}"
    justification = "JUST-#{SecureRandom.hex(4)}"
    action = "ACAO-#{SecureRandom.hex(4)}"
    barcodes = s.lot.barcodes.map(&:barcode)
    log = capture_log do
      qc_value!(s, "Nível 1", 0, by: staff, value: BigDecimal(marker_value))
      qc_value!(s, "Nível 1", 3.6, by: staff)
      block = LabQcBlock.active.sole
      req = received_requisition!(provider: s.provider, exams: [ s.exam ])
      item = type!(req.items.first, { glicose: "98" })
      Lab::Qc::RecordCorrectiveAction.call(block: block, text: action, by: staff)
      Lab::Qc::GrantException.call(block_id: block.id, item_id: item.id, justification: justification, by: lead)
      review = LabQcReviewItem.create!(lab_qc_block: block, lab_requisition_item_id: item.id)
      Lab::Qc::DecideReview.call(review: review, decision: "kept", note: note, by: lead)
    end
    payloads = DomainEvent.where("name LIKE 'lab_%'").pluck(:payload).to_json
    expect(DomainEvent.where("name LIKE 'lab_qc%'")).to exist
    ([ marker_value, note, justification, action ] + barcodes).each do |secret|
      expect(log).not_to include(secret)
      expect(payloads).not_to include(secret)
    end
  end

  # Varredura de fonte (DomainEvents.publish( é multilinha: a chamada inteira é lida
  # por balanceamento de parênteses). Todo evento 21c declarado e só com ids mais os
  # campos do contrato §9.
  describe "eventos do 21c no código" do
    ALLOWED_NON_ID_KEYS = %w[status decision source kind].freeze

    def publish_calls
      Dir[Rails.root.join("{app,lib}/**/*.rb").to_s].flat_map do |file|
        src = File.read(file)
        src.enum_for(:scan, /DomainEvents\.publish\(/).map do
          start = Regexp.last_match.end(0)
          depth = 1
          i = start
          while depth.positive? && i < src.length
            depth += 1 if src[i] == "("
            depth -= 1 if src[i] == ")"
            i += 1
          end
          [ file, src[start...(i - 1)] ]
        end
      end
    end

    let(:calls) do
      publish_calls.select { |_f, body| body =~ /\A\s*"lab_(qc|eqa|supply)/ }
                   .map { |file, body| [ file, body[/"([^"]+)"/, 1], body.sub(/\A\s*"[^"]+"\s*,?/, "") ] }
    end

    it "encontra os eventos do 21c (a varredura não está vazia)" do
      expect(calls.map { |_f, name, _p| name }.uniq.size).to eq(14)
    end

    it "todo nome publicado está declarado no initializer" do
      declared = File.read(Rails.root.join("config/initializers/domain_events.rb"))
      calls.each { |_f, name, _p| expect(declared).to include(name), "evento #{name} sem bind" }
    end

    it "o payload só tem ids e os campos do contrato" do
      calls.each do |file, name, payload|
        keys = payload.scan(/\b([a-z_]+):/).flatten
        keys.each do |key|
          expect(key.end_with?("_id") || ALLOWED_NON_ID_KEYS.include?(key)).to be(true), "#{name} (#{file}) publica #{key}"
        end
      end
    end
  end

  describe "log e Current.city no código do 21c" do
    def sources(*globs) = globs.flat_map { |g| Dir[Rails.root.join(g).to_s] }.select { |f| File.file?(f) }

    it "nenhum Platform.audit novo, nenhuma atribuição de Current.city" do
      files = sources("app/commands/lab/qc/**/*.rb", "app/commands/lab/eqa/**/*.rb", "app/commands/lab/inventory/**/*.rb",
                      "app/services/lab/qc/**/*.rb", "app/controllers/lab/**/*.rb", "app/controllers/hl7/**/*.rb", "lib/fake_middleware/**/*.rb")
      expect(files).not_to be_empty
      files.each do |f|
        src = File.read(f)
        expect(src).not_to include("Platform.audit("), f
        expect(src).not_to match(/Current\.city\s*=[^=]/), f
      end
    end

    it "log do 21c só com códigos, ids de controle e cenário (nunca valor, código de barras, justificativa ou HL7)" do
      files = sources("app/commands/lab/{qc,eqa,inventory}/**/*.rb", "app/services/lab/qc/**/*.rb", "app/services/lab/hl7/**/*.rb",
                      "app/controllers/lab/**/*.rb", "app/controllers/hl7/**/*.rb", "lib/fake_middleware/**/*.rb")
      lines = files.flat_map { |f| File.readlines(f).grep(/logger\.|Rails\.logger/).map { |l| [ f, l ] } }
      lines.each do |f, l|
        l.scan(/#\{([^}]*)\}/).flatten.reject { |expr| expr.end_with?(".size", ".count") }.each do |expr|
          expect(expr).not_to match(/value|barcode|justification|note|raw|body|message|token|text/i), "#{f}: #{l}"
        end
      end
    end
  end
end
