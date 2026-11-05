require "rails_helper"

# Módulo 31 (F-31.8; ADR 0049; contrato §10, §13, §14, §15 P18–P21, P46, P51,
# P53): o sigilo do CAPS de ponta a ponta. Um cenário completo pelas rotas reais
# (full_caps_scenario!: encaminhamento, acolhimento com matrícula F20.0 e
# substância, BPA-I, PTS, ação com evolução, ação coletiva, receita controlada,
# permanência noturna e matriciamento com caso, no "CAPS AD III Centro Vida")
# e depois as provas de ausência: rotas do cidadão (P21), resumo de saúde
# (P20), sessão (P19), linha do tempo geral da UBS (só o marcador, P18/P46),
# vínculo visto pela UBS (P46), página do PEC (nada), LEDI, avisos e SMS,
# eventos (só ids, §13), log e URLs. Relógio fixo no meio de novembro (ou o
# `now:` do exemplo). A varredura de fonte dos eventos fica no segundo grupo,
# sem o cenário.
RSpec.describe "Sigilo do CAPS (F-31.8)", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  around { |example| travel_to(example.metadata[:now] || Time.zone.local(2026, 11, 18, 15, 0)) { example.run } }

  let!(:scenario) { full_caps_scenario! }
  let(:texts) { PsychosocialHelpers::CAPS_SCENARIO_TEXTS.values }
  let(:caps_names) { [ "CAPS AD III Centro Vida", "Centro Vida", "AD III", "caps_ad_iii" ] }
  let(:clinical) { [ "F200", "F20.0", "Esquizofrenia", "Crack", "crack", "ideação", "FLUOXETINA", "fluoxetina" ] }
  let(:secrets) { texts + caps_names + clinical }
  let(:patient) { scenario[:patient] }
  let(:citizen) { scenario[:citizen] }
  let(:identifiers) { [ citizen.cpf, patient.cns, "Renato Alves Pereira" ] }
  def body = JSON.parse(response.body)

  def expect_hidden(path, extra: [])
    (secrets + extra).each { |secret| expect(response.body).not_to include(secret), "#{path} contém #{secret.inspect}" }
  end

  it "o cenário gravou o CAPS inteiro (controle positivo)" do
    enrollment = scenario[:enrollment]
    expect(enrollment).to have_attributes(cid_main: "F200", substances: [ "02" ], health_unit_id: scenario[:caps].id)
    expect(PsychosocialCarePlan.where(psychosocial_enrollment_id: enrollment.id).count).to eq(1)
    expect(PsychosocialAction.where(health_unit_id: scenario[:caps].id).pluck(:instrument))
      .to include("raas_psi", "bpa_i", "bpa_c")
    expect(PsychosocialAction.find(scenario[:refs][:note]).notes).to eq(PsychosocialHelpers::CAPS_SCENARIO_TEXTS[:note])
    expect(PsychosocialActionParticipant.where(psychosocial_action_id: scenario[:refs][:group]).count).to eq(2)
    expect(PsychosocialNightStay.where(psychosocial_enrollment_id: enrollment.id).where.not(ended_at: nil).count).to eq(1)
    expect(PsychosocialMatrixCase.where(patient_id: patient.id).count).to eq(1)
    expect(scenario[:document]).to have_attributes(kind: "prescription", psychosocial_action_id: scenario[:refs][:note], citizen_id: nil)
    expect(PerformedProcedure.where(source: "psychosocial", patient_id: patient.id).count).to eq(1)
  end

  describe "cidadão (P19–P21)" do
    before do
      # Viagens e acompanhamento (extras ao P21): os interruptores ligados, para as rotas responderem.
      Platform::Features.set!(city: scenario[:city], key: "sanitary_transport", enabled: true, maintainer: ledi_maintainer!)
      Platform::Features.set!(city: scenario[:city], key: "care_lines", enabled: true, maintainer: ledi_maintainer!)
      CityCatalog.reset_cache!
      sign_in_citizen(citizen.phone)
    end

    it "nada do CAPS no histórico (com e sem kinds[]), resumo, avisos, agendamentos, viagens, acompanhamento e sessão" do
      %w[/citizen/history /citizen/health_summary /citizen/appointments /citizen/trips /citizen/care].each do |path|
        get path, params: { citizen_id: citizen.id }
        expect(response).to have_http_status(:ok), "#{path} → #{response.status} #{response.body}"
        expect_hidden(path)
      end
      get "/citizen/history", params: { citizen_id: citizen.id }
      expect(body["entries"].map { |entry| entry["kind"] }).to include("attendance") # controle: o histórico não está vazio
      expect(body["entries"].map { |entry| entry["kind"] }).not_to include("procedure", "clinical_document")
      expect(body["entries"].map { |entry| entry["kind"] }.grep(/\Apsychosocial/)).to be_empty

      get "/citizen/history", params: { citizen_id: citizen.id, kinds: %w[clinical_document procedure attendance] }
      expect(response).to have_http_status(:ok)
      expect(body["entries"].map { |entry| entry["kind"] }).to eq(%w[attendance])
      expect_hidden("/citizen/history?kinds[]")
      %w[psychosocial psychosocial_link].each do |kind|
        get "/citizen/history", params: { citizen_id: citizen.id, kinds: [ kind ] }
        expect([ response.status, body["error"] ]).to eq([ 422, "invalid_kinds" ])
      end

      get "/citizen/notices"
      expect(response).to have_http_status(:ok)
      expect(body["notices"]).to eq([])
      expect_hidden("/citizen/notices")

      # Controle: o interruptor do CAPS está ligado e utilizável; a sessão lista os
      # utilizáveis (com o prontuário), menos o CAPS (CITIZEN_HIDDEN).
      expect(Platform::Features.usable?(scenario[:city], "psychosocial_care")).to be(true)
      get "/citizen/session"
      expect(response).to have_http_status(:ok)
      expect(body["features"]).to include("clinical_record", "patient_timeline")
      expect(body["features"]).not_to include("psychosocial_care")
      expect(body.to_json).not_to include("psychosocial")
      expect_hidden("/citizen/session")
    end

    it "o resumo de saúde não ganha problema nem medicamento do CAPS (P20); o problema da UBS aparece" do
      expect(PatientProblem.where(patient_id: patient.id)).to be_empty
      expect(PatientMedication.where(patient_id: patient.id)).to be_empty

      # Controle: consulta da UBS finalizada com o problema T90 (o caminho real do 19a).
      ciap2_release!
      doctor = scenario[:ubs_doctor]
      consultation = Consultations::Start.call(attendance: scenario[:attendance], by: doctor).payload.fetch(:consultation)
      saved = Consultations::SaveDraft.call(consultation: consultation, params: draft_body, by: doctor)
      raise "rascunho recusado: #{saved.reason} #{saved.details}" if saved.failure?

      finalized = Consultations::Finalize.call(consultation: consultation.reload, outcome_params: { "outcome" => "discharged" }, by: doctor)
      raise "finalização recusada: #{finalized.reason} #{finalized.details}" if finalized.failure?

      get "/citizen/health_summary", params: { citizen_id: citizen.id }
      expect(response).to have_http_status(:ok)
      expect(body["problems"].map { |problem| problem["code"] }).to eq([ "T90" ])
      expect(response.body).not_to include("F20", "FLUOXETINA", "fluoxetina")
      expect_hidden("/citizen/health_summary")
      expect(PatientProblem.where(patient_id: patient.id).pluck(:code)).to eq([ "T90" ])
      expect(PatientMedication.where(patient_id: patient.id)).to be_empty
    end

    it "o PDF do documento do CAPS → 404; o da UBS, do mesmo cidadão, sai (controle da rota)" do
      consultation = Consultations::Start.call(attendance: scenario[:attendance], by: scenario[:ubs_doctor]).payload.fetch(:consultation)
      ubs_note = ClinicalDocuments::Issue.call(kind: "sick_note", content: { "type" => "leave", "days" => 2 }, by: scenario[:ubs_doctor],
                                               consultation: consultation).payload.fetch(:document)

      get "/citizen/documents/#{ubs_note.id}/pdf", params: { citizen_id: citizen.id }
      expect([ response.status, response.media_type ]).to eq([ 200, "application/pdf" ])

      get "/citizen/documents/#{scenario[:document].id}/pdf", params: { citizen_id: citizen.id }
      expect([ response.status, body["error"] ]).to eq([ 404, "not_found" ])
      expect_hidden("/citizen/documents/:id/pdf")
    end
  end

  describe "UBS e PEC (P18, P46, P53)" do
    it "a linha do tempo geral mostra só o marcador 'Acompanhamento no CAPS', sem nome, CID, nota nem receita" do
      sign_in_as(scenario[:ubs_doctor])
      get "/attendance/timeline", params: { patient_id: patient.id }
      expect(response).to have_http_status(:ok)
      kinds = body["entries"].map { |entry| entry["kind"] }
      expect(kinds).to include("psychosocial_link", "attendance")
      expect(kinds).not_to include("psychosocial", "clinical_document", "procedure")
      link = body["entries"].find { |entry| entry["kind"] == "psychosocial_link" }
      expect(link).to include("title" => "Acompanhamento no CAPS", "unit" => nil, "professional" => nil, "detail_ref" => nil)
      expect_hidden("/attendance/timeline")

      get "/attendance/timeline", params: { patient_id: patient.id, kinds: %w[psychosocial] }
      expect([ response.status, body["error"] ]).to eq([ 422, "invalid_kinds" ])
    end

    it "o vínculo visto pela UBS é genérico: telefone, início, referência e o caso da equipe; nada mais" do
      sign_in_as(scenario[:ubs_doctor])
      get "/psychosocial/patients/#{patient.id}/link"
      expect(response).to have_http_status(:ok)
      expect(body.keys).to contain_exactly("enrolled", "caps", "since", "reference", "shared_cases")
      expect(body["caps"]).to eq("phone" => "4133334444")
      expect(body["shared_cases"].map { |c| c["shared_text"] }).to eq([ PsychosocialHelpers::CAPS_SCENARIO_TEXTS[:shared] ])
      shared = PsychosocialHelpers::CAPS_SCENARIO_TEXTS[:shared]
      (secrets - [ shared ]).each { |secret| expect(response.body).not_to include(secret), "vínculo contém #{secret.inspect}" }
    end

    it "a página do PEC não traz nem o marcador" do
      expect(PecTimelinesController::KINDS).not_to include("psychosocial", "psychosocial_link")
      doctor_cpf = "11144477735"
      scenario[:ubs_doctor].professional.update!(cpf: doctor_cpf)
      scenario[:city].update!(record_mode: "integrated")
      Platform::Features.set!(city: scenario[:city], key: "pec_external_view", enabled: true, maintainer: ledi_maintainer!)
      pec_settings!
      CityCatalog.reset_cache!

      get signed_pec_path(professional: doctor_cpf, citizen: citizen.cpf, cnes: scenario[:ubs].cnes)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Atendimento — UBS Boa Vista") # controle: a página tem as entradas
      expect(response.body).not_to include("Acompanhamento no CAPS", "CAPS")
      expect_hidden("/pec/timeline")
    end
  end

  describe "LEDI, avisos e SMS (§10, P21)" do
    it "nenhuma ficha, aviso ou mensagem gravada e nenhum job de aviso, SMS ou LEDI enfileirado" do
      expect(caps_side_counts).to eq(scenario[:side_counts])
      expect(caps_side_counts.values).to all(eq(0))
      expect(scenario[:jobs].uniq).to all(eq("Billing::PsychosocialProductionJob"))
      expect(scenario[:jobs]).not_to be_empty
    end

    # O CAPS não tem consulta nem escuta: o check-in em unidade `caps` é recusado
    # (P32, 422 caps_unit_not_allowed), e ação e documento do CAPS não são origem
    # de ficha (Ledi::FichaSources). O controle positivo é só o da UBS: com a
    # exportação LEDI pronta, o varredor das 23h (o caminho real que alcança a
    # cidade inteira) gera a ficha da escuta da UBS e nada do cenário do CAPS. A
    # guarda da consulta/escuta numa unidade CAPS é provada em
    # spec/jobs/ledi/caps_unit_spec.rb (Task 14).
    it "com a exportação pronta, o varredor gera a ficha da escuta da UBS (controle) e nada do CAPS",
       now: Time.zone.local(2026, 11, 18, 23, 10) do
      ledi_ready!(scenario[:city], pec_url: "https://pec.a.test", record_mode: "record", ibge_code: "4106902")
      allow(Ledi::DeliverJob).to receive(:perform_later)
      ciap2_release!
      nurse = screener!(scenario[:ubs])
      exportable_unit!(scenario[:ubs], nurse)
      attendance = walk_in_attendance!(scenario[:ubs], citizen: screening_citizen!(77))
      screening = Screenings::Start.call(attendance: attendance, by: nurse).payload[:screening]
      completed = Screenings::Complete.call(screening: screening, revision_params: revision_params, destination: "same_day",
                                            destination_params: {}, by: nurse)
      expect(completed).to be_ok

      Ledi::ScreeningFichaSweepJob.perform_now

      expect(LediOutboxEntry.pluck(:source_type, :source_id)).to eq([ [ Ledi::ScreeningFicha::SOURCE_TYPE, screening.id ] ])
      expect(LediGenerationFailure.count).to eq(0)
      caps_ids = [ scenario[:enrollment].id, scenario[:document].id, *scenario[:refs].values ] +
                 PsychosocialAction.where(health_unit_id: scenario[:caps].id).pluck(:id)
      expect(LediOutboxEntry.where(source_id: caps_ids)).to be_empty
    end
  end

  describe "eventos (§13): só ids" do
    let(:events) { DomainEvent.where(occurred_at: scenario[:started_at]..) }
    let(:caps_events) { events.where("name LIKE 'psychosocial.%'") }

    it "todo psychosocial.* do cenário leva só ids (e o mês); nenhum evento leva dado do paciente ou do CAPS" do
      expect(caps_events.distinct.pluck(:name))
        .to include("psychosocial.referral_created", "psychosocial.reception_recorded", "psychosocial.enrolled",
                    "psychosocial.care_plan_saved", "psychosocial.action_recorded", "psychosocial.night_stay_started",
                    "psychosocial.night_stay_closed", "psychosocial.matrix_support_recorded")
      caps_events.each do |event|
        event.payload.each do |key, value|
          expect(key.end_with?("_id") || key == "month").to be(true), "#{event.name} publica #{key}"
          expect(value.to_s).to match(key == "month" ? /\A\d{4}-\d{2}\z/ : /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/), "#{event.name}.#{key}"
        end
      end
      payloads = events.pluck(:name, :payload).to_json
      (secrets + identifiers).each { |secret| expect(payloads).not_to include(secret), "evento contém #{secret.inspect}" }
    end
  end

  describe "log e URLs (§14)" do
    it "o log do cenário inteiro não tem CPF, CNS, nome, CID, substância, nota nem o nome do CAPS" do
      expect(scenario[:log]).to include("/psychosocial/actions") # controle: o log capturou as requisições
      (secrets + identifiers).each { |secret| expect(scenario[:log]).not_to include(secret), "log contém #{secret.inspect}" }
      logged = scenario[:log].scan(/"(substances|cid_main|notes|needs|shared_text|reason)"\s*=>\s*([^,}]+)/)
      expect(logged.map(&:first).uniq).to include("substances", "cid_main", "notes", "needs", "shared_text", "reason") # não vazio
      expect(logged.map(&:last)).to all(include("[FILTERED]"))
    end

    it "as URLs pedidas levam só ids" do
      expect(scenario[:paths].size).to be >= 12
      (secrets + identifiers + [ "F20" ]).each do |secret|
        expect(scenario[:paths].join("\n")).not_to include(secret)
      end
    end
  end
end

# Varredura de fonte: DomainEvents.publish( é multilinha (a chamada inteira é
# lida por balanceamento de parênteses). Todo psychosocial.* declarado no
# initializer e na spec de bindings, com payload literal só de ids e `month`.
RSpec.describe "Sigilo do CAPS (F-31.8) — eventos no código" do
  let(:calls) do
    balanced_calls(/DomainEvents\.publish\(/, Dir[Rails.root.join("{app,lib}/**/*.rb").to_s])
      .select { |_file, body| body =~ /\A\s*"psychosocial\./ }
      .map { |file, body| args = top_level_args(body); [ file, args.first[/"([^"]+)"/, 1], args.drop(1) ] }
  end

  it "encontra os 17 eventos do módulo (a varredura não está vazia)" do
    expect(calls.map { |_f, name, _a| name }.uniq.size).to eq(17)
  end

  it "todo nome publicado está declarado no initializer e na spec de bindings" do
    declared = code_lines(Rails.root.join("config/initializers/domain_events.rb"))
    bindings = code_lines(Rails.root.join("spec/initializers/domain_events_bindings_spec.rb"))
    calls.map { |_f, name, _a| name }.uniq.each do |name|
      pattern = /(?<![\w.])#{Regexp.escape(name)}(?![\w.])/
      expect(declared).to match(pattern), "evento #{name} sem bind no initializer"
      expect(bindings).to match(pattern), "evento #{name} fora da spec de bindings"
      expect(DomainEvents.registry.keys).to include(name)
    end
  end

  it "o payload é literal (chave: valor), só com ids e o mês" do
    calls.each do |file, name, args|
      args.each do |arg|
        key = arg[/\A([a-z_]+):\s/, 1]
        expect(key).not_to be_nil, "#{name} (#{file}) tem payload não literal: #{arg}"
        expect(key.end_with?("_id") || key == "month").to be(true), "#{name} (#{file}) publica #{key}"
      end
    end
  end
end
