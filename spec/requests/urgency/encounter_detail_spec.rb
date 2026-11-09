require "rails_helper"

# Módulo 32a (ADR 0050; contrato §14 Q6, Q19; plano, Task 15): o detalhe do
# encontro. Com vínculo clínico na UPA (enfermagem 2235*, médico 225*), o
# detalhe inteiro; a recepção (citizen_verifier) recebe o detalhe sem o
# clínico, com a descrição do provisório; o resto → 403. Todo detalhe com
# campo clínico ou com a descrição grava a trilha (access urgency, resource
# encounter).
RSpec.describe "Urgência — detalhe do encontro", type: :request do
  let!(:city) { urgency_city! }
  let(:upa) { upa! }
  let(:nurse) { upa_nurse!(upa) }
  let(:doctor) { upa_doctor!(upa) }
  let(:description) { "Mulher de uns 30 anos, vestido verde, chegou de ambulância" }
  let(:encounter) do
    arrived!(upa, unidentified: description).tap do |e|
      classified!(e, color: "yellow", by: nurse, vital_signs: { spo2: 97 }, pain_scale: 6)
    end
  end

  def show(target = encounter, params = {}) = get("/urgency/encounters/#{target.id}", params: params)
  def trail = DomainEvent.where(name: "clinical_record.viewed").where("payload->>'resource' = 'encounter'")

  it "a enfermagem da UPA lê a queixa e a descrição do provisório, e isso grava a trilha" do
    sign_in_as(nurse)
    expect { show }.to change(trail, :count).by(1)
    expect(response).to have_http_status(:ok)
    detail = json_body["encounter"]
    expect(detail).to include("id" => encounter.id, "attendance_id" => encounter.attendance_id, "state" => "classified",
                              "color" => "yellow", "overdue" => false, "consultation_id" => nil, "outcome" => nil)
    expect(detail["patient"]).to include("patient_id" => encounter.attendance.patient_id, "unidentified" => true,
                                         "description" => description)
    expect(detail["classifications"].first).to include("position" => 1, "color" => "yellow",
                                                       "complaint" => UrgencyHelpers::COMPLAINT, "pain_scale" => 6,
                                                       "vital_signs" => { "spo2" => 97 },
                                                       "justification" => UrgencyHelpers::JUSTIFICATION)
    expect(trail.order(:occurred_at, :created_at).last.payload)
      .to include("patient_id" => encounter.attendance.patient_id, "user_id" => nurse.id, "access" => "urgency",
                  "resource" => "encounter", "person_ref" => "patient:#{encounter.attendance.patient_id}")
  end

  it "o médico da UPA também lê o detalhe inteiro" do
    sign_in_as(doctor)
    show
    expect(response).to have_http_status(:ok)
    expect(json_body.dig("encounter", "classifications", 0)).to include("complaint" => UrgencyHelpers::COMPLAINT)
  end

  it "a recepção lê sem o clínico, com a descrição (Q19), e grava a trilha; paciente identificado sem clínico não grava" do
    sign_in_as(upa_reception!)
    expect { show }.to change(trail, :count).by(1)
    expect(response).to have_http_status(:ok)
    detail = json_body["encounter"]
    expect(detail["patient"]).to include("description" => description)
    expect(detail["classifications"].first.keys).not_to include("complaint", "vital_signs", "pain_scale", "justification", "criterion")
    expect(response.body).not_to include(UrgencyHelpers::COMPLAINT)

    identified = arrived!(upa).tap { |e| classified!(e, color: "green", by: nurse) }
    expect { show(identified) }.not_to change(trail, :count)
    expect(response).to have_http_status(:ok)
    expect(json_body.dig("encounter", "patient").keys).not_to include("description")
  end

  it "sem vínculo clínico na UPA nem recepção → 403; id desconhecido → 404; dado na query → 422" do
    sign_in_as(doctor!(create_unit("UBS Vizinha")))
    expect { show }.not_to change(trail, :count)
    expect(response).to have_http_status(:forbidden)
    expect(json_body).to eq("error" => "missing_link")

    sign_in_as(staff_with("gestor-#{SecureRandom.hex(3)}@cidade.gov.br", "municipal_admin"))
    show
    expect(response).to have_http_status(:forbidden)
    expect(json_body).to eq("error" => "missing_role")

    sign_in_as(nurse)
    get "/urgency/encounters/#{SecureRandom.uuid}"
    expect(response).to have_http_status(:not_found)
    get "/urgency/encounters/nao-e-uuid"
    expect(response).to have_http_status(:not_found)
    show(encounter, cpf: "52998224725")
    expect(response).to have_http_status(:unprocessable_content)
    expect(json_body["path"]).to eq("cpf")
  end

  it "urgency_care desligado → 403 feature_disabled" do
    encounter
    Platform::Features.set!(city: city, key: Urgency::Gate::KEY, enabled: false, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
    sign_in_as(nurse)
    show
    expect(response).to have_http_status(:forbidden)
    expect(json_body).to eq("error" => "feature_disabled", "feature" => "urgency_care")
  end
end
