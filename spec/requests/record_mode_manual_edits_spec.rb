require "rails_helper"

# ADR 0028 (spec 2026-10-05 §5): além de confirmar o CNES, o admin corrige à
# mão o CNES da unidade e o CPF do profissional. CPF sai mascarado na lista.
RSpec.describe "Edição manual de CNES e CPF", type: :request do
  let(:admin) { staff_with("admin@cidade.gov.br", "municipal_admin") }
  let(:doctor) { staff_with("medica@cidade.gov.br", "health_professional") }
  def json = JSON.parse(response.body)

  before { sign_in_as(admin) }

  it "CNES da unidade: grava normalizado, limpa com null, recusa formato e repetição" do
    json_post "/attendance/units", name: "UBS Centro", kind: "ubs", cnes: "000.000-1"
    expect(json["unit"]["cnes"]).to eq("0000001")
    id = json["unit"]["id"]
    json_post "/attendance/units", name: "UBS Norte", kind: "ubs", cnes: "0000001"
    expect([ response.status, json ]).to eq([ 422, { "error" => "cnes_taken" } ])
    json_post "/attendance/units/#{id}", name: "UBS Centro", kind: "ubs", cnes: "12"
    expect([ response.status, json ]).to eq([ 422, { "error" => "invalid_cnes" } ])
    json_post "/attendance/units/#{id}", name: "UBS Centro", kind: "ubs", cnes: nil
    expect(json["unit"]["cnes"]).to be_nil
  end

  it "sem a chave cnes, o CNES já gravado não muda (R9: parte de um valor presente)" do
    json_post "/attendance/units", name: "UBS Centro", kind: "ubs", cnes: "0000001"
    id = json["unit"]["id"]
    json_post "/attendance/units/#{id}", name: "UBS Centro", kind: "ubs"
    expect(response).to have_http_status(:ok)
    expect(json["unit"]["cnes"]).to eq("0000001")
    expect(HealthUnit.find(id).cnes).to eq("0000001")
  end

  it "CPF do profissional: o admin grava; a lista mascara; repetição é 409; inválido é 422" do
    json_post "/professionals", user_id: doctor.id, professional_name: "Helena", council: "CRM", council_state: "PR",
                                registration_number: "12345", cns: "700000000000005", cpf: "529.982.247-25"
    expect(response).to have_http_status(:created)
    expect(json["professional"]).to include("cpf_masked" => "***.982.247-**", "cpf" => "52998224725")
    get "/professionals"
    expect(response.body).not_to include("52998224725")

    other = staff_with("enfermeira@cidade.gov.br", "health_professional")
    json_post "/professionals", user_id: other.id, professional_name: "Carla", council: "COREN", council_state: "PR",
                                registration_number: "54321", cns: Professionals::Cns.generate("x"), cpf: "52998224725"
    expect([ response.status, json["error"] ]).to eq([ 409, "cpf_taken" ])
    json_post "/professionals/#{Professional.first.id}", cpf: "52998224724"
    expect([ response.status, json ]).to eq([ 422, { "error" => "invalid", "fields" => [ "cpf" ] } ])
  end

  it "atualizar o profissional sem a chave cpf não apaga o CPF gravado (R9)" do
    json_post "/professionals", user_id: doctor.id, professional_name: "Helena", council: "CRM", council_state: "PR",
                                registration_number: "12345", cns: "700000000000005", cpf: "52998224725"
    id = json["professional"]["id"]
    json_post "/professionals/#{id}", professional_name: "Helena Souza"
    expect(response).to have_http_status(:ok)
    expect(Professional.find(id).cpf).to eq("52998224725")
  end
end
