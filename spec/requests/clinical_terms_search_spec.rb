require "rails_helper"

# Contratos §5: a busca do módulo 18 aceita CID-10; SIGTAP só exames da
# competência ativa. Termo no corpo, nunca na URL.
RSpec.describe "Busca de terminologia da consulta", type: :request do
  before { clinical_city!; ciap2_release!; cid10_release!; sigtap_release! }

  let(:doctor) { doctor!(create_unit) }
  def body = JSON.parse(response.body)

  it "CIAP-2 (padrão) e CID-10; terminologia desconhecida 422" do
    sign_in_as(doctor)
    json_post "/attendance/ciap2/search", q: "diabetes"
    expect(body["items"].map { |i| i["code"] }).to eq([ "T90" ])
    json_post "/attendance/ciap2/search", q: "diabetes", terminology: "cid10"
    expect(body).to eq("items" => [ { "code" => "E119", "label" => ClinicalRecordHelpers::CID10["E119"].first } ])
    json_post "/attendance/ciap2/search", q: "x", terminology: "loinc"
    expect([ response.status, body["error"] ]).to eq([ 422, "invalid_terminology" ])
  end

  it "SIGTAP: exames por nome ou código; sem competência ativa 503; interruptor desligado 403" do
    sign_in_as(doctor)
    json_post "/attendance/sigtap/search", q: "creatinina"
    expect(body).to eq("items" => [ { "code" => "0202010317", "label" => "DOSAGEM DE CREATININA" } ])
    allow(ClinicalTerms::SigtapExams).to receive(:release).and_return(nil)
    json_post "/attendance/sigtap/search", q: "creatinina"
    expect([ response.status, body["error"] ]).to eq([ 503, "terminology_unavailable" ])
    clinical_city!(enabled: false)
    json_post "/attendance/sigtap/search", q: "creatinina"
    expect(response).to have_http_status(:forbidden)
  end
end
