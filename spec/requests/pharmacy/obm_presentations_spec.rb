require "rails_helper"

# Módulo 27b, Task 13 (contrato Q16, Q19): GET /pharmacy/obm_presentations?vmp_code=.
# Exige só o estoque do domínio (nunca o `bnafar`) e algum papel de estoque.
RSpec.describe "Farmácia — apresentações do OBM", type: :request do
  let!(:city) { pharmacy_city! }
  let!(:central) { central_location! }
  let(:keeper) { pharmacy_staff!(central, "stock_keeper") }

  before do
    ObmPresentation.create!(ampp_code: "@brasil200383750", vmp_code: "@brasil1000", anvisa_registration: "1234567890123",
                            manufacturer_cnpj: "11222333000181", description: "Paracetamol 500 mg comprimido", imported_at: Time.current)
    ObmPresentation.create!(ampp_code: "@brasil200383751", vmp_code: "@brasil1000", description: "Paracetamol 750 mg", imported_at: Time.current)
    ObmPresentation.create!(ampp_code: "@brasil200383752", vmp_code: "@brasil1000", description: "Antigo", active: false, imported_at: Time.current)
    ObmPresentation.create!(ampp_code: "@brasil200383753", vmp_code: "@brasil2000", description: "Outro VMP", imported_at: Time.current)
  end

  it "devolve as apresentações ativas do VMP, sem as inativas" do
    sign_in_as(keeper)
    get "/pharmacy/obm_presentations", params: { vmp_code: "@brasil1000" }
    expect(response).to have_http_status(:ok)
    expect(json_body["items"]).to eq([
      { "ampp_code" => "@brasil200383750", "vmp_code" => "@brasil1000", "anvisa_registration" => "1234567890123",
        "manufacturer_cnpj" => "11222333000181", "description" => "Paracetamol 500 mg comprimido" },
      { "ampp_code" => "@brasil200383751", "vmp_code" => "@brasil1000", "anvisa_registration" => nil,
        "manufacturer_cnpj" => nil, "description" => "Paracetamol 750 mg" }
    ])
  end

  it "sem vmp_code → 422 com path vmp_code" do
    sign_in_as(keeper)
    get "/pharmacy/obm_presentations"
    expect([ response.status, json_body["path"] ]).to eq([ 422, "vmp_code" ])
  end

  it "sem papel de estoque → 403" do
    sign_in_as(staff_with("sem-papel-#{SecureRandom.hex(3)}@cidade.gov.br"))
    get "/pharmacy/obm_presentations", params: { vmp_code: "@brasil1000" }
    expect(response).to have_http_status(:forbidden)
  end

  it "funciona com o bnafar desligado" do
    expect(::Bnafar::Gate.usable?(city)).to be(false)
    sign_in_as(keeper)
    get "/pharmacy/obm_presentations", params: { vmp_code: "@brasil1000" }
    expect(response).to have_http_status(:ok)
  end
end
