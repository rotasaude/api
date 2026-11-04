require "rails_helper"

# Módulo 31 (contrato P4, A-D4): GET /psychosocial/prefill?patient_id&health_unit_id
# — a ESF do paciente para a matrícula, pela equipe do território (módulo 11)
# ou do cadastro individual (24a), na regra comum (CareLines::TeamPopulation).
# Só a eSF (tipo 70) conta como ESF. Sem trilha e sem dado clínico.
RSpec.describe "CAPS — pré-preenchimento da matrícula", type: :request do
  let!(:city) { psychosocial_city! }
  let(:caps) { caps! }
  let(:staff) { caps_staff!(caps) }
  let(:patient) { caps_patient! }
  let(:usf) { create_unit("USF Boa Vista", cnes: "1234567") }

  def lives_in!(unit, of: patient)
    Citizen.find_by!(patient_id: of.id).update!(neighborhood: care_neighborhood!(unit))
  end

  before { sign_in_as(staff) }

  it "paciente no território de uma eSF → ESF coberta com o CNES da USF, sem trilha" do
    team = HealthTeam.create!(health_unit: usf, ine: "0000123456", kind: "70", name: "eSF Boa Vista 1")
    lives_in!(usf)
    expect { get "/psychosocial/prefill", params: { patient_id: patient.id, health_unit_id: caps.id } }
      .not_to(change { DomainEvent.where(name: "clinical_record.viewed").count })
    expect(response).to have_http_status(:ok)
    expect(json_body).to eq("esf_covered" => true, "esf_cnes" => "1234567", "usf" => { "id" => usf.id, "name" => "USF Boa Vista" },
                            "team" => { "id" => team.id, "name" => "eSF Boa Vista 1" })
  end

  it "sem equipe, ou com equipe que não é eSF → ESF não coberta" do
    get "/psychosocial/prefill", params: { patient_id: patient.id, health_unit_id: caps.id }
    expect(json_body).to eq("esf_covered" => false, "esf_cnes" => nil, "usf" => nil, "team" => nil)

    HealthTeam.create!(health_unit: usf, ine: "0000123458", kind: "76", name: "eAP Boa Vista")
    lives_in!(usf)
    get "/psychosocial/prefill", params: { patient_id: patient.id, health_unit_id: caps.id }
    expect(json_body).to eq("esf_covered" => false, "esf_cnes" => nil, "usf" => nil, "team" => nil)
  end

  it "paciente inexistente → 404; chave estranha → 422; fora do CAPS → 403" do
    get "/psychosocial/prefill", params: { patient_id: SecureRandom.uuid, health_unit_id: caps.id }
    expect(response).to have_http_status(:not_found)
    get "/psychosocial/prefill", params: { patient_id: patient.id, health_unit_id: caps.id, cpf: "1" }
    expect([ response.status, json_body["path"] ]).to eq([ 422, "cpf" ])
    get "/psychosocial/prefill", params: { patient_id: patient.id, health_unit_id: caps!(modality: "caps_ad").id }
    expect([ response.status, json_body["error"] ]).to eq([ 403, "not_on_caps_team" ])
  end
end
