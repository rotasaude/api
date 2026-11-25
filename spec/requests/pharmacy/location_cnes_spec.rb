require "rails_helper"

# Módulo 27b, Task 6 (contrato Q13, Q23): CNES dos dois centrais (almoxarifado e
# rede de frio) pelo municipal_admin, com step-up. É dado de origem: exige só o
# estoque do domínio, nunca o `bnafar`. CNES de uma unidade de saúde → 409
# cnes_in_use; os dois centrais podem dividir o mesmo CNES.
RSpec.describe "Locais de estoque — CNES dos centrais", type: :request do
  let!(:city) { vaccination_city! }
  let(:admin) { pharmacy_admin! }

  before { Platform::Features.set!(city: city, key: "pharmacy", enabled: true, maintainer: ledi_maintainer!) }

  def json_patch(path, params = {}) = patch(path, params: params.to_json, headers: { "CONTENT_TYPE" => "application/json" })

  describe "PATCH /pharmacy/admin/locations/:id" do
    let!(:central) { central_location! }

    it "admin grava o CNES do central com step-up, com o bnafar desligado" do
      expect(Bnafar::Gate.usable?(city)).to be(false)
      stepped_up!(admin)
      json_patch "/pharmacy/admin/locations/#{central.id}", cnes: "2345678"
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("id" => central.id, "cnes" => "2345678", "bnafar_type" => "A")
      expect(central.reload.cnes).to eq("2345678")

      json_patch "/pharmacy/admin/locations/#{central.id}", cnes: nil
      expect([ response.status, json_body["cnes"] ]).to eq([ 200, nil ])
      expect(central.reload.cnes).to be_nil
    end

    it "sem step-up → 401 e nada muda" do
      sign_in_as(step_up_enrolled!(admin))
      json_patch "/pharmacy/admin/locations/#{central.id}", cnes: "2345678"
      expect([ response.status, json_body ]).to eq([ 401, { "error" => "mfa_required" } ])
      expect(central.reload.cnes).to be_nil
    end

    it "CNES malformado → 422 path cnes" do
      stepped_up!(admin)
      [ "123456", "12345678", "12345AB", 2_345_678 ].each do |bad|
        json_patch "/pharmacy/admin/locations/#{central.id}", cnes: bad
        expect([ response.status, json_body["error"], json_body["path"] ]).to eq([ 422, "invalid_request", "cnes" ])
      end
    end

    it "CNES num unit → 422 path cnes" do
      stepped_up!(admin)
      farmacia = unit_location!
      json_patch "/pharmacy/admin/locations/#{farmacia.id}", cnes: "2345678"
      expect([ response.status, json_body["error"], json_body["path"] ]).to eq([ 422, "invalid_request", "cnes" ])
      expect(farmacia.reload.cnes).to be_nil
    end

    it "CNES de uma UBS → 409 cnes_in_use" do
      create_unit("UBS Centro", cnes: "7654321")
      stepped_up!(admin)
      json_patch "/pharmacy/admin/locations/#{central.id}", cnes: "7654321"
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "cnes_in_use" } ])
      expect(central.reload.cnes).to be_nil
    end

    it "PATCH sem cnes não toca no CNES gravado" do
      central.update!(cnes: "2345678")
      stepped_up!(admin)
      json_patch "/pharmacy/admin/locations/#{central.id}", name: "Central de Abastecimento"
      expect(response).to have_http_status(:ok)
      expect(central.reload).to have_attributes(cnes: "2345678", name: "Central de Abastecimento")
    end

    it "a lista traz cnes e bnafar_type" do
      central.update!(cnes: "2345678")
      unit = create_unit("UBS Jardim", cnes: "1111111")
      farmacia = unit_location!(unit)
      sign_in_as(admin)
      get "/pharmacy/admin/locations"
      rows = json_body.fetch("locations").index_by { |row| row["id"] }
      expect(rows.fetch(central.id)).to include("cnes" => "2345678", "bnafar_type" => "A")
      expect(rows.fetch(farmacia.id)).to include("cnes" => "1111111", "bnafar_type" => "F")
    end
  end

  describe "PATCH /vaccination/admin/cold_chain_central" do
    let!(:cold) { cold_chain_central! }

    it "a rede de frio ganha CNES pelo PATCH novo, com o bnafar desligado; o nome é opcional" do
      expect(Bnafar::Gate.usable?(city)).to be(false)
      stepped_up!(admin)
      json_patch "/vaccination/admin/cold_chain_central", cnes: "3456789"
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("id" => cold.id, "kind" => "cold_chain_central", "cnes" => "3456789", "bnafar_type" => "A",
                                   "name" => "Rede de frio municipal")

      json_patch "/vaccination/admin/cold_chain_central", cnes: "3456789", name: "Central de imunização"
      expect(json_body).to include("name" => "Central de imunização", "cnes" => "3456789")
      json_patch "/vaccination/admin/cold_chain_central", cnes: nil
      expect([ response.status, json_body["cnes"] ]).to eq([ 200, nil ])
      expect(cold.reload).to have_attributes(cnes: nil, name: "Central de imunização")
    end

    it "os dois centrais podem dividir o mesmo CNES" do
      central_location!.update!(cnes: "2345678")
      stepped_up!(admin)
      json_patch "/vaccination/admin/cold_chain_central", cnes: "2345678"
      expect([ response.status, json_body["cnes"] ]).to eq([ 200, "2345678" ])
    end

    it "CNES de uma UBS → 409 cnes_in_use" do
      create_unit("UBS Centro", cnes: "7654321")
      stepped_up!(admin)
      json_patch "/vaccination/admin/cold_chain_central", cnes: "7654321"
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "cnes_in_use" } ])
      expect(cold.reload.cnes).to be_nil
    end

    it "CNES ausente, malformado ou nome inválido → 422 com o path" do
      stepped_up!(admin)
      json_patch "/vaccination/admin/cold_chain_central", name: "Outro nome"
      expect([ response.status, json_body["path"] ]).to eq([ 422, "cnes" ])
      json_patch "/vaccination/admin/cold_chain_central", cnes: "12"
      expect([ response.status, json_body["path"] ]).to eq([ 422, "cnes" ])
      json_patch "/vaccination/admin/cold_chain_central", cnes: "3456789", name: "ab"
      expect([ response.status, json_body["path"] ]).to eq([ 422, "name" ])
      expect(cold.reload.cnes).to be_nil
    end

    it "sem step-up → 401" do
      sign_in_as(step_up_enrolled!(admin))
      json_patch "/vaccination/admin/cold_chain_central", cnes: "3456789"
      expect(response).to have_http_status(:unauthorized)
      expect(cold.reload.cnes).to be_nil
    end

    it "sem vaccination → 403 feature_disabled; almoxarife (não admin) → 403" do
      keeper = staff_with("frio@cidade.gov.br", "stock_keeper")
      StockLocationStaff.create!(stock_location: cold, user: keeper, role: "stock_keeper", granted_by_user: admin, granted_at: Time.current)
      stepped_up!(keeper)
      json_patch "/vaccination/admin/cold_chain_central", cnes: "3456789"
      expect(response).to have_http_status(:forbidden)
      expect(cold.reload.cnes).to be_nil

      Platform::Features.set!(city: city, key: "vaccination", enabled: false, maintainer: ledi_maintainer!)
      stepped_up!(admin)
      json_patch "/vaccination/admin/cold_chain_central", cnes: "3456789"
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "vaccination" } ])
    end
  end

  describe "PATCH /vaccination/admin/cold_chain_central sem a rede de frio criada" do
    it "→ 404 not_found" do
      stepped_up!(admin)
      json_patch "/vaccination/admin/cold_chain_central", cnes: "3456789"
      expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
    end
  end
end
