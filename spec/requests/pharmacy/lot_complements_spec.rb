require "rails_helper"

# Módulo 27b, Task 5 (contrato §2; Q7, Q16, Q21, Q23): PATCH /pharmacy/lots/:id/bnafar.
# O complemento só exige o estoque do domínio, nunca o interruptor `bnafar`.
RSpec.describe "Farmácia — complemento BNAFAR do lote", type: :request do
  let!(:city) { pharmacy_city! }
  let!(:central) { central_location! }
  let(:unit) { create_unit("UBS Jardim das Flores") }
  let!(:farmacia) { unit_location!(unit) }
  let(:paracetamol) { catalog_item(267_778) }
  let(:keeper) { pharmacy_staff!(central, "stock_keeper") }
  let(:cnpj) { "11222333000181" }
  let!(:lot) { stocked_lot!(central, item: paracetamol, quantity: "30") }

  def patch_lot(target = lot, body = {})
    patch "/pharmacy/lots/#{target.id}/bnafar", params: { location_id: central.id, expected_version: target.reload.bnafar_version }.merge(body).to_json,
                                                headers: { "CONTENT_TYPE" => "application/json" }
  end

  let(:fields) do
    { unit_price_cents: 1250, manufacturer_cnpj: cnpj, anvisa_registration: "1234567890123", health_program: "AFB" }
  end

  it "almoxarife completa e recebe missing: [] com a versão nova" do
    sign_in_as(keeper)
    patch_lot(lot, fields)
    expect(response).to have_http_status(:ok)
    expect(json_body).to eq("id" => lot.id,
                            "bnafar" => { "unit_price_cents" => 1250, "manufacturer_cnpj" => cnpj, "manufacturer_international" => false,
                                          "anvisa_registration" => "1234567890123", "health_program" => "AFB", "ium" => nil,
                                          "ampp_code" => nil, "version" => 1, "missing" => [] })
    expect(lot.reload).to have_attributes(unit_price_cents: 1250, manufacturer_cnpj: cnpj, bnafar_version: 1)
  end

  it "completo parcial devolve o que ainda falta" do
    sign_in_as(keeper)
    patch_lot(lot, unit_price_cents: 100)
    expect(json_body.dig("bnafar", "missing")).to eq(%w[manufacturer_cnpj anvisa_registration health_program])
  end

  it "versão velha → 409 lot_bnafar_changed; sem versão → 422 expected_version_required" do
    sign_in_as(keeper)
    patch_lot(lot, fields)
    patch "/pharmacy/lots/#{lot.id}/bnafar", params: { location_id: central.id, expected_version: 0, unit_price_cents: 5 }.to_json,
                                             headers: { "CONTENT_TYPE" => "application/json" }
    expect([ response.status, json_body["error"] ]).to eq([ 409, "lot_bnafar_changed" ])

    patch "/pharmacy/lots/#{lot.id}/bnafar", params: { location_id: central.id, unit_price_cents: 5 }.to_json,
                                             headers: { "CONTENT_TYPE" => "application/json" }
    expect([ response.status, json_body["error"], json_body["path"] ]).to eq([ 422, "expected_version_required", "expected_version" ])
  end

  it "troca de CNPJ preenchido → 422 lot_mismatch; troca de preço passa" do
    sign_in_as(keeper)
    patch_lot(lot, fields)
    patch_lot(lot, manufacturer_cnpj: "11444777000161")
    expect([ response.status, json_body["error"], json_body["path"] ]).to eq([ 422, "lot_mismatch", "manufacturer_cnpj" ])
    expect(lot.reload.bnafar_version).to eq(1)

    patch_lot(lot, unit_price_cents: 2000)
    expect(response).to have_http_status(:ok)
    expect(lot.reload).to have_attributes(unit_price_cents: 2000, bnafar_version: 2)
  end

  it "nada muda → 200 sem subir a versão" do
    sign_in_as(keeper)
    patch_lot(lot, fields)
    patch_lot(lot, fields)
    expect(response).to have_http_status(:ok)
    expect(lot.reload.bnafar_version).to eq(1)
  end

  it "campo inválido → 422 com path do campo; chave desconhecida → invalid_request" do
    sign_in_as(keeper)
    patch_lot(lot, health_program: "XYZ")
    expect([ response.status, json_body["error"], json_body["path"] ]).to eq([ 422, "program_unknown", "health_program" ])
    patch_lot(lot, lot_number: "OUTRO")
    expect([ response.status, json_body["error"], json_body["path"] ]).to eq([ 422, "invalid_request", "lot_number" ])
  end

  it "farmacêutico de outro local → 404 (sem movimento do lote ali); do local com movimento passa" do
    other = pharmacy_staff!(farmacia, "pharmacist")
    sign_in_as(other)
    patch "/pharmacy/lots/#{lot.id}/bnafar", params: { location_id: farmacia.id, expected_version: 0 }.merge(fields).to_json,
                                             headers: { "CONTENT_TYPE" => "application/json" }
    expect(response).to have_http_status(:not_found)

    pharmacist = pharmacy_staff!(central, "pharmacist")
    sign_in_as(pharmacist)
    patch_lot(lot, fields)
    expect(response).to have_http_status(:ok)
  end

  it "pharmacy_assistant → 403 e quem não tem papel nenhum → 403" do
    sign_in_as(pharmacy_staff!(central, "pharmacy_assistant"))
    patch_lot(lot, fields)
    expect([ response.status, json_body["error"] ]).to eq([ 403, "missing_role" ])
    expect(lot.reload.bnafar_version).to eq(0)
  end

  it "municipal_admin completa" do
    sign_in_as(pharmacy_admin!)
    patch_lot(lot, fields)
    expect(response).to have_http_status(:ok)
  end

  it "funciona com bnafar desligado (Q23): só o estoque do domínio vale" do
    expect(Bnafar::Gate.usable?(city)).to be(false)
    sign_in_as(keeper)
    patch_lot(lot, fields)
    expect(response).to have_http_status(:ok)
  end

  it "com o estoque desligado → 403 feature_disabled" do
    Platform::Features.set!(city: city, key: "pharmacy", enabled: false, maintainer: ledi_maintainer!)
    sign_in_as(keeper)
    patch_lot(lot, fields)
    expect(response).to have_http_status(:forbidden)
    expect(json_body["error"]).to eq("feature_disabled")
  end

  it "lote e local inexistentes → 404 e 422 location_id" do
    sign_in_as(keeper)
    patch "/pharmacy/lots/#{SecureRandom.uuid}/bnafar", params: { location_id: central.id, expected_version: 0 }.to_json,
                                                        headers: { "CONTENT_TYPE" => "application/json" }
    expect(response).to have_http_status(:not_found)
    patch "/pharmacy/lots/#{lot.id}/bnafar", params: { expected_version: 0 }.to_json, headers: { "CONTENT_TYPE" => "application/json" }
    expect([ response.status, json_body["path"] ]).to eq([ 422, "location_id" ])
  end

  it "vacina (Q21): rejeita manufacturer_cnpj e o complemento do resto passa" do
    Platform::Features.set!(city: city, key: "vaccination", enabled: true, maintainer: ledi_maintainer!)
    pharmacy_admin!
    cold = cold_chain_central!
    vaccine = vaccine_lot!(cold, code: "42", manufacturer_key: "serum")
    sign_in_as(pharmacy_staff!(cold, "stock_keeper"))
    patch "/pharmacy/lots/#{vaccine.id}/bnafar", params: { location_id: cold.id, expected_version: 0, manufacturer_cnpj: cnpj }.to_json,
                                                 headers: { "CONTENT_TYPE" => "application/json" }
    expect([ response.status, json_body["error"], json_body["path"] ]).to eq([ 422, "invalid_request", "manufacturer_cnpj" ])

    patch "/pharmacy/lots/#{vaccine.id}/bnafar", params: { location_id: cold.id, expected_version: 0 }.merge(fields.except(:manufacturer_cnpj)).to_json,
                                                 headers: { "CONTENT_TYPE" => "application/json" }
    expect(response).to have_http_status(:ok)
    expect(json_body.dig("bnafar", "missing")).to eq(%w[manufacturer_cnpj])
  end

  it "complemento só com ANVISA diferente da apresentação do AMPP já gravado → anvisa_mismatch e lote intacto; coerente passa" do
    ObmPresentation.create!(ampp_code: "@brasil20038375080", vmp_code: "@brasil1000", anvisa_registration: "1234567890123",
                            description: "Paracetamol 500 mg", imported_at: Time.current)
    lot.update!(ampp_code: "@brasil20038375080", bnafar_version: 1)
    sign_in_as(keeper)
    patch_lot(lot, anvisa_registration: "99999999999")
    expect([ response.status, json_body["error"], json_body["path"] ]).to eq([ 422, "anvisa_mismatch", "anvisa_registration" ])
    expect(lot.reload).to have_attributes(anvisa_registration: nil, bnafar_version: 1)

    patch_lot(lot, anvisa_registration: "1234567890123")
    expect(response).to have_http_status(:ok)
    expect(lot.reload).to have_attributes(anvisa_registration: "1234567890123", bnafar_version: 2)
  end

  it "evento stock_lot.bnafar_completed só com ids" do
    sign_in_as(keeper)
    patch_lot(lot, fields)
    expect(DomainEvent.where(name: "stock_lot.bnafar_completed").sole.payload).to eq("stock_lot_id" => lot.id, "user_id" => keeper.id)
    patch_lot(lot, fields)
    expect(DomainEvent.where(name: "stock_lot.bnafar_completed").count).to eq(1)
  end
end
