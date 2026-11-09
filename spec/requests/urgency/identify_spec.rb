require "rails_helper"

# Módulo 32a (ADR 0050, R4; contrato §4 e §14 Q6, Q15, Q17, Q19, Q23):
# POST /urgency/encounters/:id/identify { patient_id } | { new_patient,
# duplicates_reviewed? } pela recepção (citizen_verifier). → 200 `{ encounter:
# <detalhe>, merged, moved, kept_duplicates }`; a recepção recebe o detalhe sem
# o clínico (Q19). O evento urgency.patient_identified leva só ids e as contagens.
RSpec.describe "Identificação do paciente provisório", type: :request do
  let!(:city) { urgency_city! }
  let(:upa) { upa! }
  let(:nurse) { upa_nurse!(upa) }
  let(:encounter) { arrived!(upa, unidentified: "Homem, 50 anos, desacordado na praça") }
  # Ansioso: depois da fusão, encounter.patient já é o real.
  let!(:provisional) { encounter.patient }
  let(:path) { "/urgency/encounters/#{encounter.id}/identify" }
  before { sign_in_as(upa_reception!) }

  it "com paciente existente: funde, devolve o detalhe sem o clínico e publica o evento com merged_from_id" do
    classified!(encounter, color: "orange", by: nurse, vital_signs: { spo2: 93 }, pain_scale: 8)
    real = urgency_patient!(1)
    json_post path, patient_id: real.id
    expect(response).to have_http_status(:ok)
    expect(json_body.keys).to contain_exactly("encounter", "merged", "moved", "kept_duplicates")
    expect(json_body).to include("merged" => true, "moved" => 1, "kept_duplicates" => 0)
    expect(json_body.dig("encounter", "patient")).to eq("patient_id" => real.id, "name" => real.display_name,
                                                        "cns_masked" => real.cns_masked, "unidentified" => false)
    classification = json_body.dig("encounter", "classifications", 0)
    expect(classification.keys).not_to include("complaint", "vital_signs", "pain_scale", "justification", "criterion")
    expect(DomainEvent.where(name: "urgency.patient_identified").sole.payload)
      .to eq("encounter_id" => encounter.id, "patient_id" => real.id, "merged_from_id" => provisional.id, "moved" => 1,
             "kept_duplicates" => 0)
    expect(provisional.reload.merged_into_id).to eq(real.id)

    json_post path, patient_id: urgency_patient!(2).id
    expect(response).to have_http_status(:conflict)
    expect(json_body).to eq("error" => "already_identified")
  end

  it "com paciente novo: o provisório recebe os dados, sem fusão; o nome digitado não vai ao log nem ao evento" do
    log = capture_log do
      json_post path, new_patient: { full_name: "Benedito Ramos Filho", birth_date: "1960-07-07", sex: "male", no_cpf_reason: "3" }
    end
    expect(response).to have_http_status(:ok)
    expect(json_body).to include("merged" => false, "moved" => 0, "kept_duplicates" => 0)
    expect(json_body.dig("encounter", "patient")).to include("patient_id" => provisional.id, "name" => "Benedito Ramos Filho",
                                                             "unidentified" => false)
    expect(json_body.dig("encounter", "patient")).not_to have_key("description")
    expect(DomainEvent.where(name: "urgency.patient_identified").sole.payload)
      .to eq("encounter_id" => encounter.id, "patient_id" => provisional.id)
    expect(log).not_to include("Benedito")
    expect(log).not_to include("praça")
  end

  it "duplicado suspeito → 409 com os candidatos; CPF já cadastrado → 409 cpf_taken" do
    twin = urgency_patient!(5, cpf: false)
    typed = { full_name: twin.full_name, birth_date: twin.birth_date, sex: twin.sex, mother_name: twin.mother_name, no_cpf_reason: "3" }
    json_post path, new_patient: typed
    expect(response).to have_http_status(:conflict)
    expect(json_body).to eq("error" => "duplicate_suspected", "path" => "new_patient",
                            "candidates" => [ { "patient_id" => twin.id, "display_name" => twin.display_name,
                                                "birth_date" => twin.birth_date, "has_cpf" => false } ])
    json_post path, new_patient: { full_name: "Joana Ribeiro Matos", birth_date: "1975-04-03", sex: "female", cpf: urgency_patient!(6).cpf }
    expect(response).to have_http_status(:conflict)
    expect(json_body).to eq("error" => "cpf_taken", "path" => "new_patient.cpf")
    json_post path, new_patient: typed, duplicates_reviewed: true
    expect(response).to have_http_status(:ok)
  end

  it "recusas: forma, patient_id desconhecido (404), alvo provisório, encontro de paciente identificado, chave desconhecida, query" do
    json_post path, {}
    expect(json_body).to include("error" => "invalid_request", "path" => "patient")
    json_post path, patient_id: SecureRandom.uuid
    expect(response).to have_http_status(:not_found)
    expect(json_body).to eq("error" => "patient_not_found", "path" => "patient_id")
    json_post path, patient_id: arrived!(upa, unidentified: "Outro provisório").patient.id
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_body).to include("error" => "invalid_request", "path" => "patient_id")
    json_post path, patient_id: urgency_patient!(3).id, reason: "x"
    expect(json_body).to include("error" => "invalid_request", "path" => "reason")
    post "#{path}?patient_id=#{urgency_patient!(4).id}", params: {}.to_json, headers: { "CONTENT_TYPE" => "application/json" }
    expect(json_body).to include("error" => "invalid_request", "path" => "patient_id")

    known = arrived!(upa, patient: urgency_patient!(7))
    json_post "/urgency/encounters/#{known.id}/identify", patient_id: urgency_patient!(8).id
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_body).to include("error" => "not_unidentified")

    json_post "/urgency/encounters/#{SecureRandom.uuid}/identify", patient_id: urgency_patient!(9).id
    expect(response).to have_http_status(:not_found)
    expect(provisional.reload.merged_into_id).to be_nil
  end

  it "sem o papel da recepção → 403; interruptor desligado → 403 feature_disabled" do
    real = urgency_patient!(1)
    sign_in_as(nurse)
    json_post path, patient_id: real.id
    expect(response).to have_http_status(:forbidden)
    expect(json_body).to eq("error" => "missing_role")
    sign_in_as(upa_reception!)
    Platform::Features.set!(city: city, key: "urgency_care", enabled: false, maintainer: ledi_maintainer!)
    json_post path, patient_id: real.id
    expect(json_body).to eq("error" => "feature_disabled", "feature" => "urgency_care")
    expect(provisional.reload.merged_into_id).to be_nil
  end
end
