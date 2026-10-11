require "rails_helper"

# Contrato §5: o próprio profissional lê e grava endereço e telefone de
# prescritor; o endereço vai cifrado; nada no log.
RSpec.describe "Contato do prescritor", type: :request do
  before { documents_city! }

  let(:unit) { create_unit }
  let(:doctor) { doctor!(unit) }
  def body = JSON.parse(response.body)

  it "lê vazio, grava, lê de volta; PUT exige JSON (415 exato)" do
    sign_in_as(doctor)
    get "/attendance/professional_profile/contact"
    expect(body).to eq("address" => nil, "phone" => doctor.professional.phone)
    log = capture_log do
      put "/attendance/professional_profile/contact",
          params: { address: ControlledPrescriptionHelpers::ADDRESS, phone: "4133330000" }, as: :json
    end
    expect(response).to have_http_status(:ok)
    expect(body).to eq("address" => ControlledPrescriptionHelpers::ADDRESS, "phone" => "4133330000")
    expect(log).not_to include("Araucárias", "3333")
    expect(doctor.professional.reload.prescriber_contact).to include("phone" => "4133330000")
    put "/attendance/professional_profile/contact", params: { phone: "4133330000" }
    expect(response).to have_http_status(:unsupported_media_type)
  end

  it "complemento só com espaço é descartado; número s/n é aceito" do
    sign_in_as(doctor)
    put "/attendance/professional_profile/contact",
        params: { address: ControlledPrescriptionHelpers::ADDRESS.merge("complement" => " ", "number" => "s/n"), phone: "4133330000" }, as: :json
    expect(response).to have_http_status(:ok)
    expect(body["address"]).not_to have_key("complement")
    expect(body["address"]["number"]).to eq("s/n")
  end

  it "422 com o campo; recepção sem perfil → 404" do
    sign_in_as(doctor)
    put "/attendance/professional_profile/contact", params: { address: ControlledPrescriptionHelpers::ADDRESS.merge("uf" => "ZZ"), phone: "4133330000" }, as: :json
    expect([ response.status, body ]).to eq([ 422, { "error" => "invalid_address", "field" => "uf" } ])
    put "/attendance/professional_profile/contact", params: { address: ControlledPrescriptionHelpers::ADDRESS, phone: "12" }, as: :json
    expect([ response.status, body["error"] ]).to eq([ 422, "invalid_phone" ])
    put "/attendance/professional_profile/contact", params: { address: ControlledPrescriptionHelpers::ADDRESS, phone: "(41) 3333-0000" }, as: :json
    expect([ response.status, body["error"] ]).to eq([ 422, "invalid_phone" ])
    put "/attendance/professional_profile/contact", params: { address: ControlledPrescriptionHelpers::ADDRESS.merge("zip" => "80010-000"), phone: "4133330000" }, as: :json
    expect([ response.status, body ]).to eq([ 422, { "error" => "invalid_address", "field" => "zip" } ])
    # FW5: caractere de controle em campo de texto é recusado com o campo (NUL nem cabe no jsonb).
    put "/attendance/professional_profile/contact", params: { address: ControlledPrescriptionHelpers::ADDRESS.merge("street" => "Rua\u0000 X"), phone: "4133330000" }, as: :json
    expect([ response.status, body ]).to eq([ 422, { "error" => "invalid_address", "field" => "street" } ])
    put "/attendance/professional_profile/contact", params: { address: ControlledPrescriptionHelpers::ADDRESS.merge("complement" => "Bloco\u0007"), phone: "4133330000" }, as: :json
    expect([ response.status, body ]).to eq([ 422, { "error" => "invalid_address", "field" => "complement" } ])
    expect(doctor.professional.reload.prescriber_address_data).to be_nil
    sign_in_as(verifier!)
    get "/attendance/professional_profile/contact"
    expect([ response.status, body["error"] ]).to eq([ 404, "not_found" ])
  end
end
