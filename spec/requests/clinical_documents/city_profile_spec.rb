require "rails_helper"

# Contrato §6 (Desvio 12): o CNPJ da cidade (secretaria ou fundo), exigido na
# receita de enfermagem. Escrita do municipal_admin com step-up; leitura
# também do profissional (a tela da receita avisa quando falta).
RSpec.describe "CNPJ da cidade", type: :request do
  before { clinical_city!; city_profile! }

  it "admin grava (numérico ou alfanumérico); DV errado 422; sem step-up 401; sem JSON 415" do
    admin = municipal_admin!
    sign_in_as(step_up_enrolled!(admin))
    json_put "/clinical_documents/city_profile", cnpj: "76.001.234/0001-15"
    expect([ response.status, json_body ]).to eq([ 401, { "error" => "mfa_required" } ])

    stepped_up!(admin)
    json_put "/clinical_documents/city_profile", cnpj: "76.001.234/0001-15"
    expect(response).to have_http_status(:ok)
    expect(json_body).to eq("name" => CityProfile.current.name, "cnpj" => "76001234000115")
    json_put "/clinical_documents/city_profile", cnpj: "12ABC34501DE35"
    expect(CityProfile.current.cnpj).to eq("12ABC34501DE35")
    json_put "/clinical_documents/city_profile", cnpj: "76001234000116"
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_cnpj" } ])
    put "/clinical_documents/city_profile", params: { cnpj: "76001234000115" }
    expect(response).to have_http_status(:unsupported_media_type)
  end

  it "profissional lê; recepção não; profissional não escreve" do
    unit = create_unit
    sign_in_as(doctor!(unit))
    get "/clinical_documents/city_profile"
    expect(json_body).to include("cnpj" => nil)
    json_put "/clinical_documents/city_profile", cnpj: "76001234000115"
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
    sign_in_as(verifier!)
    get "/clinical_documents/city_profile"
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
  end

  it "prontuário desligado → 403 feature_disabled" do
    clinical_city!(enabled: false)
    sign_in_as(municipal_admin!)
    get "/clinical_documents/city_profile"
    expect(json_body).to eq("error" => "feature_disabled", "feature" => "clinical_record")
  end
end
