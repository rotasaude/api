require "rails_helper"

# Módulo 31: a equipe do CAPS (sem health_professional) busca a CID-10 para
# registrar a matrícula; a CIAP-2 segue exclusiva do profissional de saúde.
# Dado de referência público (rótulos), sem dado de paciente.
RSpec.describe "CAPS — busca de terminologia", type: :request do
  before { psychosocial_city!; ciap2_release!; cid10_release! }

  let(:caps) { caps! }
  def body = JSON.parse(response.body)
  def cid10_items = [ { "code" => "E119", "label" => ClinicalRecordHelpers::CID10["E119"].first } ]

  [ false, true ].each do |lead|
    role = lead ? "psychosocial_lead" : "psychosocial_staff"

    it "#{role} busca CID-10: 200 com items" do
      sign_in_as(caps_staff!(caps, lead: lead))
      json_post "/attendance/ciap2/search", q: "diabetes", terminology: "cid10"
      expect([ response.status, body ]).to eq([ 200, { "items" => cid10_items } ])
    end

    it "#{role} busca CIAP-2 (padrão ou explícita): 403 missing_role" do
      sign_in_as(caps_staff!(caps, lead: lead))
      json_post "/attendance/ciap2/search", q: "diabetes"
      expect([ response.status, body["error"] ]).to eq([ 403, "missing_role" ])
      json_post "/attendance/ciap2/search", q: "diabetes", terminology: "ciap2"
      expect([ response.status, body["error"] ]).to eq([ 403, "missing_role" ])
    end
  end

  it "health_professional segue igual: CIAP-2 e CID-10" do
    sign_in_as(doctor!(create_unit))
    json_post "/attendance/ciap2/search", q: "diabetes"
    expect(body["items"].map { |i| i["code"] }).to eq([ "T90" ])
    json_post "/attendance/ciap2/search", q: "diabetes", terminology: "cid10"
    expect([ response.status, body ]).to eq([ 200, { "items" => cid10_items } ])
  end

  it "viewer recebe 403 nas duas terminologias" do
    sign_in_as(staff_with("viewer-#{SecureRandom.hex(3)}@cidade.gov.br", "viewer"))
    json_post "/attendance/ciap2/search", q: "diabetes", terminology: "cid10"
    expect(response).to have_http_status(:forbidden)
    json_post "/attendance/ciap2/search", q: "diabetes"
    expect(response).to have_http_status(:forbidden)
  end

  it "terminologia desconhecida pela equipe do CAPS: 403 (nada além da CID-10)" do
    sign_in_as(caps_staff!(caps))
    json_post "/attendance/ciap2/search", q: "x", terminology: "loinc"
    expect(response).to have_http_status(:forbidden)
  end
end
