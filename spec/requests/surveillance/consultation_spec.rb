require "rails_helper"

# Módulo 25, Task 8 (contrato §4, §15 K4, K5, K12(b)): sugestão e "Notificar
# suspeita" na consulta. Também a primeira cobertura de request do
# Surveillance::BaseController (render_failure, body_param).
RSpec.describe "Vigilância na consulta", type: :request do
  before { surveillance_city! }

  let(:unit) { HealthUnit.create!(name: "UBS Consulta #{SecureRandom.hex(2)}", kind: "ubs") }
  let(:doctor) { doctor!(unit) }
  let(:citizen) { verified_citizen!(41) }
  let(:dengue_add) { [ { "terminology" => "cid10", "code" => "A90", "action" => "add" } ] }
  let(:json_headers) { { "Content-Type" => "application/json" } }

  def draft!(problems, who: citizen, by: doctor)
    c = started_consultation!(unit: unit, doctor: by, citizen: who)
    Consultations::SaveDraft.call(consultation: c, params: draft_body("evaluated_problems" => problems), by: by)
    c.reload
  end

  def suggestions(consultation) = (get("/attendance/consultations/#{consultation.id}/notification_suggestions") && json_body["suggestions"])

  def notify(consultation, **body)
    post "/surveillance/notifications", params: { consultation_id: consultation.id, disease_code: "dengue" }.merge(body).to_json,
                                        headers: json_headers
  end

  def viewed_events = DomainEvent.where(name: "clinical_record.viewed")

  it "rascunho com A90 add sugere dengue sem trilha; notificar devolve 201 e a sugestão some" do
    c = draft!(dengue_add)
    sign_in_as(doctor)
    trail = viewed_events.count
    get "/attendance/consultations/#{c.id}/notification_suggestions"
    expect(response).to have_http_status(:ok)
    expect(json_body["suggestions"].map { |s| [ s.dig("disease", "code"), s["matched_code"] ] }).to eq([ %w[dengue A90] ])
    expect(json_body["suggestions"].first["disease"].keys).to match_array(%w[code name deadline cid10 ciap2 repeat_after_days sinan_form
                                                                              local list_version notes id active])
    expect(viewed_events.count).to eq(trail)
    expect(DiseaseNotification.count).to eq(0)

    notify(c, symptoms_on: Date.yesterday.iso8601)
    expect(response).to have_http_status(:created)
    expect(json_body).to include("origin" => "consultation", "status" => "notified", "symptoms_on" => Date.yesterday.iso8601)

    expect(suggestions(c)).to eq([])
    notify(c)
    expect(response).to have_http_status(:conflict)
    expect(json_body).to eq("error" => "already_notified")
  end

  it "o 201 traz a forma nominal completa (§2 + K5) e grava uma trilha por pessoa" do
    c = draft!(dengue_add)
    neighborhood = Neighborhood.create!(name: "Centro #{SecureRandom.hex(2)}", source: "manual")
    allow(Surveillance::PatientNeighborhood).to receive(:for).and_return(neighborhood.id)
    sign_in_as(doctor)
    trail = viewed_events.count

    notify(c, symptoms_on: Time.zone.today.iso8601)
    expect(response).to have_http_status(:created)

    notification = DiseaseNotification.find(json_body["id"])
    patient = notification.patient
    expect(json_body.keys).to match_array(%w[id patient disease origin status classification suspected_on symptoms_on unit notifier deadline
                                              due_at overdue official_number resident_elsewhere residence_ibge neighborhood consultation_id
                                              closed_at entered_at dismissed_at version form events])
    expect(json_body).to include(
      "origin" => "consultation", "status" => "notified", "classification" => nil, "deadline" => "weekly", "overdue" => false,
      "official_number" => nil, "resident_elsewhere" => false, "residence_ibge" => nil, "consultation_id" => c.id,
      "closed_at" => nil, "entered_at" => nil, "dismissed_at" => nil, "version" => 1,
      "suspected_on" => Time.zone.today.iso8601, "due_at" => notification.due_at.iso8601
    )
    expect(json_body["patient"]).to eq("id" => patient.id, "display_name" => patient.display_name, "has_cpf" => true,
                                       "cns_masked" => patient.cns_masked)
    expect(json_body["disease"]).to eq("code" => "dengue", "name" => Surveillance::Diseases.find("dengue").name,
                                       "deadline" => json_body["deadline"])
    expect(json_body["unit"]).to eq("id" => unit.id, "cnes" => notification.unit_cnes, "name" => unit.name)
    expect(json_body["notifier"]).to eq("name" => Screenings::Json.staff_name(doctor))
    expect(json_body["neighborhood"]).to eq("id" => neighborhood.id, "name" => neighborhood.name)
    expect(json_body["form"]).to be_a(Hash)
    expect(json_body["events"]).to match([ { "status" => "notified", "at" => a_string_matching(/\A\d{4}-/), "by" => { "name" => Screenings::Json.staff_name(doctor) },
                                              "reason" => nil } ])

    new_events = viewed_events.order(:created_at).last(viewed_events.count - trail)
    expect(new_events.map(&:payload)).to eq([ { "patient_id" => patient.id, "user_id" => doctor.id, "access" => "surveillance",
                                                "reason_code" => nil, "person_ref" => "patient:#{patient.id}" } ])
  end

  it "sem item add não sugere; outra autora 403; surveillance desligado 403 feature_disabled" do
    c = draft!([ { "terminology" => "ciap2", "code" => "T90", "action" => "add" } ])
    sign_in_as(doctor)
    expect(suggestions(c)).to eq([])

    sign_in_as(doctor!(unit))
    get "/attendance/consultations/#{c.id}/notification_suggestions"
    expect(response).to have_http_status(:forbidden)
    expect(json_body).to eq("error" => "not_author")

    Platform::Features.set!(city: Current.city, key: "surveillance", enabled: false, maintainer: ledi_maintainer!)
    sign_in_as(doctor)
    get "/attendance/consultations/#{c.id}/notification_suggestions"
    expect(response).to have_http_status(:forbidden)
    expect(json_body).to eq("error" => "feature_disabled", "feature" => "surveillance")
    notify(c)
    expect(response).to have_http_status(:forbidden)
    expect(json_body).to eq("error" => "feature_disabled", "feature" => "surveillance")
  end

  it "prontuário desligado com a vigilância ligada: feature_disabled aponta clinical_record" do
    c = draft!(dengue_add)
    sign_in_as(doctor)
    Platform::Features.set!(city: Current.city, key: "clinical_record", enabled: false, maintainer: ledi_maintainer!)
    get "/attendance/consultations/#{c.id}/notification_suggestions"
    expect(response).to have_http_status(:forbidden)
    expect(json_body).to eq("error" => "feature_disabled", "feature" => "clinical_record")
    notify(c)
    expect(response).to have_http_status(:forbidden)
    expect(json_body).to eq("error" => "feature_disabled", "feature" => "clinical_record")
    expect(DiseaseNotification.count).to eq(0)
  end

  it "finalizar sem notificar segue, com a vigilância ligada e a sugestão pendente: nada nasce no caminho da requisição" do
    c = draft!(dengue_add)
    sign_in_as(doctor)
    expect(suggestions(c).map { |s| s.dig("disease", "code") }).to eq(%w[dengue])
    post "/attendance/consultations/#{c.id}/finalize", params: { outcome: { outcome: "discharged" } }.to_json, headers: json_headers
    expect(response).to have_http_status(:ok)
    expect(c.reload).to be_finalized
    expect(DiseaseNotification.count).to eq(0)
  end

  it "a API aceita notificar a consulta já finalizada da própria autora (K12(b)); a sugestão da finalizada vem dos problemas gravados" do
    c = finalized_consultation!(unit: unit, doctor: doctor, citizen: citizen, evaluated_problems: dengue_add)
    sign_in_as(doctor)
    expect(suggestions(c).map { |s| [ s.dig("disease", "code"), s["matched_code"] ] }).to eq([ %w[dengue A90] ])
    notify(c)
    expect(response).to have_http_status(:created)
    expect(json_body).to include("origin" => "consultation", "consultation_id" => c.id)
    expect(suggestions(c)).to eq([])
  end

  it "adendo com A90 add sugere; resolve e evaluate de problema existente nunca" do
    c = finalized_consultation!(unit: unit, doctor: doctor, citizen: citizen)
    sign_in_as(doctor)
    expect(suggestions(c)).to eq([])
    changes = { "evaluated_problems" => [ { "terminology" => "cid10", "code" => "A90", "action" => "add" } ] }
    added = Consultations::AddAddendum.call(consultation: c, by: doctor, reason: "Esqueci de registrar a dengue", text: "Adendo", changes: changes)
    expect(added).to be_ok
    expect(suggestions(c).map { |s| s.dig("disease", "code") }).to eq(%w[dengue])

    problem = PatientProblem.find_by!(patient_id: c.patient_id, terminology: "cid10", code: "A90")
    other = draft!([ { "terminology" => "cid10", "code" => "A90", "action" => "evaluate", "problem_id" => problem.id } ], who: citizen)
    expect(suggestions(other)).to eq([])
    resolved = draft!([ { "terminology" => "cid10", "code" => "A90", "action" => "resolve", "problem_id" => problem.id } ],
                      who: verified_citizen!(44))
    expect(suggestions(resolved)).to eq([])
  end

  it "enfermeiro (223505) notifica pelo CIAP-2; vínculo fora de 225*/2235* → cbo_not_allowed" do
    nurse = doctor!(unit, cbo: "223505")
    c = started_consultation!(unit: unit, doctor: nurse, citizen: citizen)
    Consultations::SaveDraft.call(consultation: c, params: draft_body("evaluated_problems" => [ { "terminology" => "ciap2", "code" => "B90", "action" => "add" } ]), by: nurse)
    sign_in_as(nurse)
    get "/attendance/consultations/#{c.id}/notification_suggestions"
    expect(json_body["suggestions"].map { |s| s.dig("disease", "code") }).to eq(%w[hiv_aids])
    notify(c, disease_code: "hiv_aids")
    expect(response).to have_http_status(:created)

    psychologist = doctor!(unit, cbo: "251510") # o 19a aceita na consulta (tabela do MIAI); a notificação não
    other = started_consultation!(unit: unit, doctor: psychologist, citizen: verified_citizen!(42))
    sign_in_as(psychologist)
    notify(other, disease_code: "tuberculose")
    expect(response).to have_http_status(:forbidden)
    expect(json_body).to eq("error" => "cbo_not_allowed")
    expect(DiseaseNotification.where(patient_id: other.patient_id)).to be_empty
  end

  it "qualquer doença da lista pode ser notificada à mão, sem sugestão; nunca toca a consulta" do
    c = draft!([ { "terminology" => "ciap2", "code" => "T90", "action" => "add" } ])
    before_attrs = c.attributes
    sign_in_as(doctor)
    expect(suggestions(c)).to eq([])
    notify(c, disease_code: "tuberculose")
    expect(response).to have_http_status(:created)
    expect(json_body.dig("disease", "code")).to eq("tuberculose")
    expect(c.reload.attributes).to eq(before_attrs)
  end

  it "doença fora da lista → 422 invalid_disease; sintomas malformados ou no futuro → 422 invalid_symptoms_on" do
    c = draft!(dengue_add)
    sign_in_as(doctor)
    [ "nao_existe", nil, 7, "local_x" ].each do |code|
      notify(c, disease_code: code)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body).to eq("error" => "invalid_disease")
    end
    [ "ontem", "2026-13-40", "27/10/2026", 20_261_027, (Time.zone.today + 1).iso8601 ].each do |value|
      notify(c, symptoms_on: value)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body).to eq("error" => "invalid_symptoms_on")
    end
    expect(DiseaseNotification.count).to eq(0)
  end

  it "corpo inválido: sem consultation_id → 422 invalid_request; id desconhecido ou descartado → 404; dado na query não vale" do
    c = draft!(dengue_add)
    sign_in_as(doctor)
    post "/surveillance/notifications", params: { disease_code: "dengue" }.to_json, headers: json_headers
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_body).to eq("error" => "invalid_request")
    post "/surveillance/notifications", params: { consultation_id: SecureRandom.uuid, disease_code: "dengue" }.to_json, headers: json_headers
    expect(response).to have_http_status(:not_found)
    post "/surveillance/notifications", params: { consultation_id: "nao-e-uuid", disease_code: "dengue" }.to_json, headers: json_headers
    expect(response).to have_http_status(:not_found)

    # consulta e doença só do corpo: na query contam como ausentes
    post "/surveillance/notifications?consultation_id=#{c.id}&disease_code=dengue", params: {}.to_json, headers: json_headers
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_body).to eq("error" => "invalid_request")
    post "/surveillance/notifications?disease_code=dengue", params: { consultation_id: c.id }.to_json, headers: json_headers
    expect(json_body).to eq("error" => "invalid_disease")
    expect(DiseaseNotification.count).to eq(0)
  end

  it "só a autora notifica; quem não é profissional de saúde recebe missing_role" do
    c = draft!(dengue_add)
    sign_in_as(doctor!(unit))
    notify(c)
    expect(response).to have_http_status(:forbidden)
    expect(json_body).to eq("error" => "not_author")

    sign_in_as(surveillance_officer!)
    notify(c)
    expect(response).to have_http_status(:forbidden)
    expect(json_body).to eq("error" => "missing_role")
    get "/attendance/consultations/#{c.id}/notification_suggestions"
    expect(response).to have_http_status(:forbidden)
    expect(json_body).to eq("error" => "missing_role")
    expect(DiseaseNotification.count).to eq(0)
  end

  it "o 409 traz notification_id só para quem tem o papel surveillance" do
    existing = notification!(patient: Patients::Resolve.call(citizen).payload.fetch(:patient), disease_code: "dengue", unit: unit)
    c = draft!(dengue_add)
    Membership.create!(user: doctor, role: "surveillance", granted_at: Time.current)
    sign_in_as(doctor)
    notify(c)
    expect(response).to have_http_status(:conflict)
    expect(json_body).to eq("error" => "already_notified", "notification_id" => existing.id)
  end

  it "o 409 do médico sem o papel surveillance não traz o id" do
    notification!(patient: Patients::Resolve.call(citizen).payload.fetch(:patient), disease_code: "dengue", unit: unit)
    c = draft!(dengue_add)
    sign_in_as(doctor)
    notify(c)
    expect(response).to have_http_status(:conflict)
    expect(json_body).to eq("error" => "already_notified")
  end

  it "uma suspeita já notificada não aparece como sugestão" do
    patient = Patients::Resolve.call(citizen).payload.fetch(:patient)
    notification!(patient: patient, disease_code: "dengue", unit: unit)
    c = draft!(dengue_add)
    sign_in_as(doctor)
    expect(suggestions(c)).to eq([])
  end

  it "uma sugestão por doença (a do primeiro código que casa), na ordem dos itens" do
    c = draft!([ { "terminology" => "cid10", "code" => "A920", "action" => "add" },
                 { "terminology" => "cid10", "code" => "B24", "action" => "add" },
                 { "terminology" => "ciap2", "code" => "B90", "action" => "add" },
                 { "terminology" => "cid10", "code" => "A90", "action" => "add" } ])
    sign_in_as(doctor)
    expect(suggestions(c).map { |s| [ s.dig("disease", "code"), s["matched_code"] ] })
      .to eq([ %w[chikungunya A920], %w[hiv_aids B24], %w[dengue A90] ])
  end

  it "não deixa CPF nem a doença no log" do
    c = draft!(dengue_add)
    sign_in_as(doctor)
    log = capture_log { notify(c, symptoms_on: Date.yesterday.iso8601) }
    expect(response).to have_http_status(:created)
    expect(log).not_to include(citizen.cpf)
    expect(log).not_to include("dengue")
  end
end
