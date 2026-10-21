require "rails_helper"

# Contrato §3: busca na SIGTAP da competência (reaproveita a plataforma),
# com instrumento, CID exigido, sexo e idades; termo 2..60; sem release 503.
RSpec.describe "Faturamento — busca SIGTAP", type: :request do
  before { billing_city! }

  let(:unit) { upa! }

  it "por nome e por início de código, para profissional e faturista" do
    sign_in_as(doctor!(unit))
    get "/billing/sigtap/search", params: { q: "urgencia" }
    item = json_body["procedures"].find { |p| p["code"] == "0301060029" }
    expect(item).to eq("code" => "0301060029", "name" => "ATENDIMENTO DE URGENCIA C/ OBSERVACAO ATE 24 HORAS EM ATENCAO ESPECIALIZADA",
                       "instruments" => %w[bpa_i], "requires_cid" => true, "sex" => nil, "age_min_months" => nil, "age_max_months" => nil)
    sign_in_as(billing_clerk!)
    get "/billing/sigtap/search", params: { q: "020102" }
    expect(json_body["procedures"].find { |p| p["code"] == "0201020033" }).to include("instruments" => %w[bpa_c bpa_i], "sex" => "F",
                                                                                    "age_min_months" => 300)
  end

  it "termo curto 422, recepção 403, competência sem release 503" do
    sign_in_as(billing_clerk!)
    get "/billing/sigtap/search", params: { q: "a" }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_body).to eq("error" => "invalid_query")
    get "/billing/sigtap/search", params: { q: "consulta", competence: "199901" }
    expect(response).to have_http_status(:service_unavailable)
    expect(json_body).to eq("error" => "terminology_unavailable")
    sign_in_as(verifier!)
    get "/billing/sigtap/search", params: { q: "consulta" }
    expect(response).to have_http_status(:forbidden)
  end
end
