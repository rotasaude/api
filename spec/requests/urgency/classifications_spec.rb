require "rails_helper"

# Módulo 32a (ADR 0050; contrato §5 e §14 Q1, Q2, Q3, Q6, Q18, Q19, Q22):
# classificação de risco, reclassificação e a prévia da cor. Só a enfermagem
# (2235) com vínculo ativo na UPA classifica; a dor é `pain_scale`, fora dos
# sinais, e obrigatória; cor diferente da sugerida (ou sem sugestão) exige
# justificativa; cada classificação grava o tempo máximo da cor no momento.
RSpec.describe "Classificação de risco", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let!(:city) { urgency_city! }
  let(:upa) { upa! }
  let(:nurse) { upa_nurse!(upa) }
  let!(:protocol) { urgency_protocol! }
  let(:encounter) { arrived!(upa, patient: urgency_patient!(1)) }
  before { sign_in_as(nurse) }

  def classify(target = encounter, **body) = json_post("/urgency/encounters/#{target.id}/classifications", body)

  it "aceita a cor sugerida sem justificativa e leva o encontro a classified, no formato do detalhe" do
    expect { classify(complaint: "Falta de ar há 2 horas", vital_signs: { spo2: 87 }, pain_scale: 2, color: "red") }
      .to change { DomainEvent.where(name: "urgency.classified").count }.by(1)
    expect(response).to have_http_status(:created)
    expect(json_body["suggested"]).to eq("color" => "red", "criterion" => "SpO2 abaixo de 90%")
    detail = json_body["encounter"]
    expect(detail).to include("id" => encounter.id, "attendance_id" => encounter.attendance_id, "health_unit_id" => upa.id,
                              "state" => "classified", "color" => "red", "overdue" => false, "consultation_id" => nil,
                              "consultation_status" => nil, "outcome" => nil)
    expect(detail["classifications"].last).to include(
      "position" => 1, "color" => "red", "max_wait_minutes" => 0, "complaint" => "Falta de ar há 2 horas",
      "vital_signs" => { "spo2" => 87 }, "pain_scale" => 2, "justification" => nil, "criterion" => "SpO2 abaixo de 90%",
      "suggested" => { "color" => "red", "criterion" => "SpO2 abaixo de 90%" }, "protocol_definition_id" => protocol.id
    )
    expect(detail.dig("classifications", 0, "by")).to include("cbo_code" => "223505")
    expect(encounter.reload).to have_attributes(state: "classified", color: "red")
    expect(encounter.first_classified_at).to be_present
    event = DomainEvent.where(name: "urgency.classified").last
    expect(event.payload.keys).to contain_exactly("encounter_id", "classification_id")
  end

  it "a resposta grava a trilha do encontro (access urgency, resource encounter)" do
    expect { classify(complaint: "Tosse seca", vital_signs: {}, pain_scale: 0, color: "blue", justification: "Sem sinal de alarme algum") }
      .to change { DomainEvent.where(name: "clinical_record.viewed").count }.by(1)
    trail = DomainEvent.where(name: "clinical_record.viewed").last.payload
    expect(trail).to include("access" => "urgency", "resource" => "encounter", "patient_id" => encounter.patient.id)
  end

  it "trocar a cor sugerida exige justificativa de 10+ caracteres; sem protocolo, toda cor exige" do
    classify(complaint: "Dor lombar", vital_signs: {}, pain_scale: 9, color: "yellow")
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_body).to include("error" => "justification_required", "path" => "justification")
    classify(complaint: "Dor lombar", vital_signs: {}, pain_scale: 9, color: "yellow", justification: "curta")
    expect(json_body["error"]).to eq("justification_required")
    classify(complaint: "Dor lombar", vital_signs: {}, pain_scale: 9, color: "yellow", justification: "Dor crônica conhecida, sem sinal de alarme")
    expect(response).to have_http_status(:created)
    last = json_body.dig("encounter", "classifications").last
    expect(last).to include("color" => "yellow", "criterion" => nil, "justification" => "Dor crônica conhecida, sem sinal de alarme",
                            "suggested" => { "color" => "orange", "criterion" => "Dor intensa (8 a 10)" })
    protocol.update_columns(status: "retired")
    other = arrived!(upa, patient: urgency_patient!(2))
    classify(other, complaint: "Tosse", vital_signs: {}, pain_scale: 0, color: "blue")
    expect(json_body["error"]).to eq("justification_required")
    classify(other, complaint: "Tosse", vital_signs: {}, pain_scale: 0, color: "blue", justification: "Classificação manual sem protocolo")
    expect(response).to have_http_status(:created)
    expect(json_body["suggested"]).to be_nil
    expect(json_body.dig("encounter", "classifications", 0)).to include("suggested" => nil, "max_wait_minutes" => 240,
                                                                        "protocol_definition_id" => nil)
  end

  it "pain_scale é obrigatório e fica fora dos sinais; recusas de forma com o path" do
    classify(complaint: "Dor lombar", vital_signs: {}, color: "blue", justification: "Sem sinal de alarme algum")
    expect(json_body).to include("error" => "pain_scale_required", "path" => "pain_scale")
    classify(complaint: "Dor lombar", vital_signs: {}, pain_scale: nil, color: "blue", justification: "Sem sinal de alarme algum")
    expect(json_body["error"]).to eq("pain_scale_required")
    classify(complaint: "Dor lombar", vital_signs: {}, pain_scale: 11, color: "blue")
    expect(json_body).to include("error" => "invalid_request", "path" => "pain_scale")
    classify(complaint: "Dor lombar", vital_signs: { pain_score: 5 }, pain_scale: 5, color: "green")
    expect(json_body).to include("error" => "invalid_request", "path" => "vital_signs.pain_score")
    classify(complaint: "Dor lombar", vital_signs: { spo2: 30 }, pain_scale: 0, color: "blue")
    expect(json_body).to include("error" => "invalid_request", "path" => "vital_signs.spo2")
    classify(complaint: "Dor lombar", vital_signs: { systolic: 120 }, pain_scale: 0, color: "blue")
    expect(json_body["path"]).to eq("vital_signs.diastolic")
    classify(complaint: "Do", vital_signs: {}, pain_scale: 0, color: "purple")
    expect(json_body["problems"]).to contain_exactly({ "path" => "complaint", "error" => "invalid_request" },
                                                     { "path" => "color", "error" => "invalid_request" })
    classify(complaint: "Dor lombar", vital_signs: {}, pain_scale: 0, color: "blue", note: "x")
    expect(json_body).to include("error" => "invalid_request", "path" => "note")
    expect(UrgencyClassification.count).to eq(0)
  end

  it "a queixa, o critério e os sinais nunca vão para o log, o evento nem a recusa" do
    log = capture_log do
      classify(complaint: "Queixa sigilosa de teste", vital_signs: { spo2: 87, temperature_c: "37,9" }, pain_scale: 2, color: "red")
      classify(complaint: "Queixa sigilosa de teste", vital_signs: {}, pain_scale: 2, color: "orange")
    end
    expect(log).not_to include("Queixa sigilosa")
    expect(log).not_to include("SpO2 abaixo de 90%")
    # Sinal como texto com vírgula: não colide com uuid nem com tempo do log.
    expect(log).not_to include("37,9")
    expect(response.body).not_to include("Queixa sigilosa")
    expect(DomainEvent.where(name: %w[urgency.classified clinical_record.viewed]).map(&:payload).to_s).not_to include("Queixa sigilosa")
    expect(UrgencyClassification.connection.select_value("SELECT complaint FROM urgency_classifications LIMIT 1"))
      .not_to include("Queixa sigilosa")
  end

  it "reclassificar acrescenta; a cor vigente é a última; o estado não muda; o evento leva só ids" do
    classified!(encounter, color: "green", by: nurse, pain_scale: 5, justification: nil)
    first_at = encounter.first_classified_at
    classify(complaint: "Piora da dor", vital_signs: {}, pain_scale: 9, color: "orange")
    expect(response).to have_http_status(:created)
    expect(encounter.reload.classifications.map(&:color)).to eq(%w[green orange])
    expect(encounter.classifications.map(&:position)).to eq([ 1, 2 ])
    expect(encounter).to have_attributes(state: "classified", color: "orange", first_classified_at: first_at)
    event = DomainEvent.where(name: "urgency.reclassified").last
    expect(event.payload.keys).to contain_exactly("encounter_id", "classification_id")
    expect(event.payload["classification_id"]).to eq(encounter.current_classification_id)
  end

  it "justificativa dada fora de 10..500 onde não é exigida é recusada com o path, nunca descartada" do
    classify(complaint: "Falta de ar", vital_signs: { spo2: 87 }, pain_scale: 2, color: "red", justification: "curta")
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_body).to include("error" => "invalid_request", "path" => "justification")
    expect(json_body["problems"]).to eq([ { "path" => "justification", "error" => "invalid_request" } ])
    classify(complaint: "Falta de ar", vital_signs: { spo2: 87 }, pain_scale: 2, color: "red", justification: "x" * 501)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_body).to include("error" => "invalid_request", "path" => "justification")
    classify(complaint: "Falta de ar", vital_signs: { spo2: 87 }, pain_scale: 2, color: "orange", justification: "x" * 501)
    expect(json_body).to include("error" => "justification_required", "path" => "justification")
    expect(UrgencyClassification.count).to eq(0)
    classify(complaint: "Falta de ar", vital_signs: { spo2: 87 }, pain_scale: 2, color: "red", justification: "Confere com a sugestão")
    expect(response).to have_http_status(:created)
    expect(json_body.dig("encounter", "classifications", 0, "justification")).to eq("Confere com a sugestão")
  end

  it "atendimento fechado com o encontro ainda classificado → 409 encounter_closed" do
    classified!(encounter, color: "green", by: nurse, pain_scale: 5, justification: nil)
    closed = Attendances::Close.call(attendance: encounter.attendance, outcome: "left", referral_unit_id: nil, referral_note: nil,
                                     by: upa_reception!)
    expect(closed).to be_ok
    expect(encounter.reload.state).to eq("classified")
    classify(complaint: "Piora da dor", vital_signs: {}, pain_scale: 9, color: "orange")
    expect(response).to have_http_status(:conflict)
    expect(json_body["error"]).to eq("encounter_closed")
    expect(encounter.reload.classifications.count).to eq(1)
  end

  it "encontro fechado → 409 encounter_closed; encontro inexistente → 404" do
    classified!(encounter, color: "green", by: nurse, pain_scale: 5, justification: nil)
    encounter.update_columns(state: "closed")
    classify(complaint: "Piora da dor", vital_signs: {}, pain_scale: 9, color: "orange")
    expect(response).to have_http_status(:conflict)
    expect(json_body["error"]).to eq("encounter_closed")
    json_post "/urgency/encounters/#{SecureRandom.uuid}/classifications", complaint: "Tosse", vital_signs: {}, pain_scale: 0, color: "blue"
    expect(response).to have_http_status(:not_found)
  end

  it "Review Focus 4: o estouro usa o tempo gravado na classificação, não o do protocolo de agora" do
    travel_to(40.minutes.ago) { classified!(encounter, color: "yellow", by: nurse, justification: "Conferido pela enfermeira") }
    protocol.update_columns(status: "retired")
    urgency_protocol!(levels: UrgencyHelpers::LEVELS.map { |l| l["color"] == "yellow" ? l.merge("max_wait_minutes" => 30) : l }, version: 2)
    expect(encounter.reload.current_classification.max_wait_minutes).to eq(60)
    expect(Urgency::Json.encounter(encounter, clinical: true)[:overdue]).to be(false)
    later = arrived!(upa, patient: urgency_patient!(3))
    classified!(later, color: "yellow", by: nurse, justification: "Conferido pela enfermeira")
    expect(later.reload.current_classification.max_wait_minutes).to eq(30)
    travel_to(35.minutes.from_now) do
      expect(Urgency::Json.encounter(later, clinical: true)[:overdue]).to be(true)
      expect(Urgency::Json.encounter(encounter.reload, clinical: true)[:overdue]).to be(true)
    end
  end

  it "médico, técnico de enfermagem (3222) e recepção não classificam; sem vínculo na UPA → missing_link" do
    sign_in_as(upa_doctor!(upa))
    classify(complaint: "Tosse", vital_signs: {}, pain_scale: 0, color: "blue")
    expect(response).to have_http_status(:forbidden)
    expect(json_body["error"]).to eq("cbo_not_allowed")
    sign_in_as(upa_nurse!(upa, cbo: "322205"))
    classify(complaint: "Tosse", vital_signs: {}, pain_scale: 0, color: "blue")
    expect(json_body["error"]).to eq("cbo_not_allowed")
    sign_in_as(upa_reception!)
    classify(complaint: "Tosse", vital_signs: {}, pain_scale: 0, color: "blue")
    expect(json_body["error"]).to eq("missing_role")
    sign_in_as(upa_nurse!(create_unit("UBS Z")))
    classify(complaint: "Tosse", vital_signs: {}, pain_scale: 0, color: "blue")
    expect(json_body["error"]).to eq("missing_link")
    expect(UrgencyClassification.count).to eq(0)
  end

  describe "POST /urgency/suggest" do
    def levels = UrgencyHelpers::LEVELS

    it "a prévia sugere pelo protocolo ativo com os níveis, sem gravar nada nem trilha" do
      encounter
      expect { json_post "/urgency/suggest", encounter_id: encounter.id, complaint: "Febre", vital_signs: { temperature_c: "39,4" }, pain_scale: 0 }
        .not_to(change { [ UrgencyClassification.count, DomainEvent.count ] })
      expect(response).to have_http_status(:ok)
      expect(json_body).to eq("suggested" => { "color" => "yellow", "criterion" => "Febre de 39 °C ou mais", "rule_id" => "febre-alta" },
                              "levels" => levels)
      expect(encounter.reload.state).to eq("waiting_classification")
    end

    it "sem dor avaliada não há cor; sem protocolo, suggested nulo e os tempos padrão" do
      json_post "/urgency/suggest", encounter_id: encounter.id, vital_signs: { spo2: 80 }, pain_scale: nil
      expect(json_body).to eq("suggested" => nil, "levels" => levels)
      protocol.update_columns(status: "retired")
      json_post "/urgency/suggest", encounter_id: encounter.id, vital_signs: { spo2: 80 }, pain_scale: 3
      expect(json_body).to eq("suggested" => nil, "levels" => Urgency::Catalog::DEFAULT_MAX_WAIT.map { |c, m| { "color" => c, "max_wait_minutes" => m } })
    end

    it "o perfil do paciente entra na condição; provisório sem perfil" do
      urgency_protocol!(rules: [ { "id" => "idoso", "when" => { "gte" => [ "profile.age", 40 ] }, "color" => "orange", "criterion" => "40 anos ou mais" } ],
                        version: 2)
      json_post "/urgency/suggest", encounter_id: encounter.id, vital_signs: {}, pain_scale: 0
      expect(json_body.dig("suggested", "rule_id")).to eq("idoso")
      provisional = arrived!(upa, unidentified: "Homem, cerca de 50 anos")
      json_post "/urgency/suggest", encounter_id: provisional.id, vital_signs: {}, pain_scale: 0
      expect(json_body["suggested"]).to be_nil
    end

    it "recusas: técnico 3222, encontro ausente ou inexistente, sinais implausíveis e pain_score dentro dos sinais" do
      json_post "/urgency/suggest", encounter_id: encounter.id, vital_signs: { pain_score: 4 }, pain_scale: 4
      expect(json_body).to include("error" => "invalid_request", "path" => "vital_signs.pain_score")
      json_post "/urgency/suggest", encounter_id: encounter.id, vital_signs: { heart_rate: 900 }, pain_scale: 4
      expect(json_body["path"]).to eq("vital_signs.heart_rate")
      json_post "/urgency/suggest", encounter_id: encounter.id, vital_signs: {}, pain_scale: 12
      expect(json_body["path"]).to eq("pain_scale")
      json_post "/urgency/suggest", encounter_id: SecureRandom.uuid, vital_signs: {}, pain_scale: 0
      expect(response).to have_http_status(:not_found)
      json_post "/urgency/suggest", vital_signs: {}, pain_scale: 0
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body).to include("error" => "invalid_request", "path" => "encounter_id")
      sign_in_as(upa_nurse!(upa, cbo: "322205"))
      json_post "/urgency/suggest", encounter_id: encounter.id, vital_signs: {}, pain_scale: 0
      expect(json_body["error"]).to eq("cbo_not_allowed")
    end
  end
end

# Contrato §14 Q19 (preflight C-14): sem acesso clínico (a recepção ao
# identificar ou registrar evasão), o detalhe omite o clínico e mantém a
# descrição do provisório.
RSpec.describe Urgency::Json do
  let!(:city) { urgency_city! }
  let(:upa) { upa! }
  let(:nurse) { upa_nurse!(upa) }

  it "sem acesso clínico: sem queixa, sinais, dor, justificativa nem critério; a descrição fica" do
    urgency_protocol!
    encounter = arrived!(upa, unidentified: "Mulher, cerca de 70 anos, trazida pelo SAMU")
    classified!(encounter, color: "red", by: nurse, vital_signs: { spo2: 85 }, pain_scale: 3, justification: nil)
    clinical = described_class.encounter(encounter, clinical: true)
    expect(clinical[:patient]).to include(unidentified: true, description: "Mulher, cerca de 70 anos, trazida pelo SAMU")
    expect(clinical[:classifications].first).to include(complaint: UrgencyHelpers::COMPLAINT, pain_scale: 3, criterion: "SpO2 abaixo de 90%")

    reception = described_class.encounter(encounter, clinical: false)
    expect(reception[:patient][:description]).to eq("Mulher, cerca de 70 anos, trazida pelo SAMU")
    item = reception[:classifications].first
    expect(item.keys).not_to include(:complaint, :vital_signs, :pain_scale, :justification, :criterion)
    expect(item[:suggested]).to eq(color: "red")
    expect(item).to include(color: "red", max_wait_minutes: 0)
    expect(reception.to_s).not_to include(UrgencyHelpers::COMPLAINT)
    expect(reception.to_s).not_to include("SpO2")
  end
end
