require "rails_helper"

# Contrato §11 T3 e §12 P1 (padrão do patient_lookup do 21a/22): CPF só no
# corpo; trilha por pessoa mostrada; par só declarado 409; limite por usuário.
RSpec.describe "Linhas de cuidado — busca de pessoa pelo CPF", type: :request do
  before { care_city! }

  let(:unit) { care_unit! }
  let(:doctor) { care_doctor!(unit) }

  def viewed
    DomainEvent.where(name: "clinical_record.viewed").order(:occurred_at, :created_at).to_a
               .select { |e| e.payload["access"] == "care_line" }
  end

  it "acha o paciente ou o par validado sem paciente; não cria paciente; uma trilha por pessoa mostrada" do
    patient = care_patient!(age: 58, sex: "male")
    pair = Citizen.find_by!(patient_id: patient.id)
    citizen = care_citizen!(age: 62, sex: "female")
    sign_in_as(doctor)
    json_post "/care_lines/person_lookup", cpf: pair.cpf
    expect(json_body).to eq("person" => { "patient_id" => patient.id, "citizen_id" => pair.id, "display_name" => patient.display_name,
                                          "cpf_masked" => pair.cpf_masked, "verified" => true })
    expect { json_post "/care_lines/person_lookup", cpf: citizen.cpf }.not_to change(Patient, :count)
    expect(json_body["person"]).to include("patient_id" => nil, "citizen_id" => citizen.id, "verified" => true)
    expect(viewed.map { |e| e.payload.values_at("user_id", "patient_id", "person_ref") })
      .to eq([ [ doctor.id, patient.id, "patient:#{patient.id}" ], [ doctor.id, nil, "citizen:#{citizen.id}" ] ])
  end

  it "par só declarado 409; CPF desconhecido 404; CPF inválido 422 (sem trilha); sem vínculo 403" do
    Citizen.create!(cpf: "39053344705", phone: "+5541999990002", verification_level: "declared")
    sign_in_as(doctor)
    json_post "/care_lines/person_lookup", cpf: "390.533.447-05"
    expect([ response.status, json_body["error"] ]).to eq([ 409, "citizen_not_verified" ])
    json_post "/care_lines/person_lookup", cpf: "111.444.777-35"
    expect([ response.status, json_body["error"] ]).to eq([ 404, "person_not_found" ])
    json_post "/care_lines/person_lookup", cpf: "123"
    expect([ response.status, json_body["error"] ]).to eq([ 422, "invalid_cpf" ])
    expect(viewed).to be_empty
    sign_in_as(care_admin!)
    json_post "/care_lines/person_lookup", cpf: "111.444.777-35"
    expect([ response.status, json_body["error"] ]).to eq([ 403, "missing_role" ])
  end

  it "limite de 30 por minuto por usuário" do
    allow(CareLines::PersonLookupsController::RateLimitStore).to receive(:increment).and_return(31)
    sign_in_as(doctor)
    json_post "/care_lines/person_lookup", cpf: "111.444.777-35"
    expect([ response.status, json_body["error"] ]).to eq([ 429, "too_many_requests" ])
  end

  it "o CPF nunca vai para o log de parâmetros" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    expect(filter.filter("cpf" => "39053344705")).to eq("cpf" => "[FILTERED]")
  end
end
