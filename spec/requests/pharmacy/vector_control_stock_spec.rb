require "rails_helper"

# Módulo 35a, Task 7 (ADR 0054, decisão 29; contrato §4; Q4, Q8; plano, A-12,
# A-13): o insumo de campo é o terceiro domínio do razão do 27a. O admin cria
# o local vector_control numa UVZ pela tela de locais; a equipe do local dá
# entrada, transfere e ajusta pelas rotas do 27a com o produto no lugar do
# CATMAT; linha de outro domínio → item_not_allowed_here, nos dois sentidos;
# a dispensação nunca aceita o local; a UVZ com o local não troca de tipo.
RSpec.describe "Estoque do insumo de campo pelas rotas do 27a", type: :request do
  let!(:city) { vector_city! }
  let(:uvz) { create_unit("UVZ Centro", kind: "environmental_surveillance") }
  let(:product) { vector_product!(code: "PYR", name: "Pyriproxyfen 0,5% G", unit: "g") }
  let(:location) { vector_location!(uvz, name: "UVZ — insumos") }
  let(:keeper) { vector_keeper!(location) }
  let(:today) { Time.zone.today }

  def line(**over)
    { vector_product_id: product.id, lot_number: "PYR-01", expires_on: (today + 200).iso8601, quantity: "40" }.merge(over)
  end

  def receipt(items = [ line ], target: location)
    json_post "/pharmacy/receipts", location_id: target.id, document: { kind: "invoice", number: "GUIA-9", supplier: "Regional de Saúde" },
                                    items: items
  end

  def problems = json_body["problems"]

  it "admin cria local vector_control na UVZ (201) e não numa UBS (422 path health_unit_id); um por unidade; aparece na lista" do
    pharmacy_city!
    admin = pharmacy_admin!
    stepped_up!(admin)
    json_post "/pharmacy/admin/locations", kind: "vector_control", health_unit_id: create_unit("UBS Norte").id, name: "Insumos UBS"
    expect([ response.status, json_body["error"], json_body["path"] ]).to eq([ 422, "invalid_request", "health_unit_id" ])

    json_post "/pharmacy/admin/locations", kind: "vector_control", health_unit_id: uvz.id, name: "UVZ — insumos", active: true
    expect(response).to have_http_status(:created)
    created = StockLocation.find_by!(kind: "vector_control")
    expect(json_body).to include("id" => created.id, "kind" => "vector_control", "health_unit" => { "id" => uvz.id, "name" => "UVZ Centro" },
                                 "active" => true, "staff" => [])
    expect(uvz.reload.dispenses).to be(false)

    json_post "/pharmacy/admin/locations", kind: "vector_control", health_unit_id: uvz.id, name: "UVZ — segundo"
    expect([ response.status, json_body["error"] ]).to eq([ 409, "unit_taken" ])

    get "/pharmacy/admin/locations"
    expect(json_body["locations"].map { |row| row["id"] }).to include(created.id)
  end

  it "entrada de lote de produto no local vector_control; CATMAT nele → item_not_allowed_here; produto em local de farmácia → item_not_allowed_here" do
    sign_in_as(keeper)
    receipt
    expect(response).to have_http_status(:created)
    lot = StockLot.find_by!(vector_product_id: product.id)
    expect(lot).to have_attributes(item_kind: "vector_control", catalog_item_id: nil, dispensing_unit: "g", lot_number: "PYR-01")
    expect(json_body["items"].sole).to eq(
      "lot" => { "id" => lot.id, "lot_number" => "PYR-01", "expires_on" => (today + 200).iso8601, "manufacturer" => nil,
                 "item" => { "catalog_item_id" => nil, "catmat_code" => nil, "vector_product_id" => product.id, "code" => "PYR",
                             "item_kind" => "vector_control", "name" => "Pyriproxyfen 0,5% G", "unit" => "g", "dispensing_unit" => "g",
                             "controlled" => false, "controlled_list" => nil } },
      "quantity" => "40.00"
    )
    expect(Pharmacy::Ledger.balance(location_id: location.id, lot_id: lot.id)).to eq(BigDecimal("40"))

    receipt([ { catalog_item_id: SecureRandom.uuid, lot_number: "X", expires_on: "2027-01-01", quantity: "1" } ])
    expect(problems).to eq([ { "path" => "items[0]", "error" => "item_not_allowed_here" } ])
    receipt([ line(package: { units_per_package: 10, packages: 4 }) ])
    expect(problems).to eq([ { "path" => "items[0].package", "error" => "invalid_request" } ])
    inactive = vector_product!(active: false)
    receipt([ line(vector_product_id: inactive.id) ])
    expect(problems).to eq([ { "path" => "items[0].vector_product_id", "error" => "invalid_item" } ])

    pharmacy_city!
    farmacia = unit_location!
    sign_in_as(pharmacy_staff!(farmacia, "stock_keeper"))
    receipt(target: farmacia)
    expect(problems).to include("path" => "items[0]", "error" => "item_not_allowed_here")
  end

  it "abertura, transferência entre locais vector_control, perda e extrato pelas rotas do 27a" do
    sign_in_as(keeper)
    json_post "/pharmacy/openings", location_id: location.id, items: [ line(quantity: "10") ]
    expect(response).to have_http_status(:created)
    expect(StockOpening.sole).to have_attributes(vector_product_id: product.id, stock_location_id: location.id)
    json_post "/pharmacy/openings", location_id: location.id, items: [ line(lot_number: "PYR-02", quantity: "1") ]
    expect(problems).to eq([ { "path" => "items[0].vector_product_id", "error" => "opening_exists" } ])
    lot = StockLot.find_by!(vector_product_id: product.id)

    other = vector_location!
    json_post "/pharmacy/transfers", from_location_id: location.id, to_location_id: other.id, items: [ { lot_id: lot.id, quantity: "4" } ]
    expect(response).to have_http_status(:created)
    json_post "/pharmacy/transfers", from_location_id: location.id, to_location_id: location.id, items: [ { lot_id: lot.id, quantity: "1" } ]
    expect(problems).to include("path" => "to_location_id", "error" => "invalid_request")

    stepped_up!(keeper)
    json_post "/pharmacy/adjustments", location_id: location.id, lot_id: lot.id, kind: "loss", quantity: "1",
                                       reason: "Saco rasgado no transporte"
    expect(response).to have_http_status(:created)
    expect(Pharmacy::Ledger.balance(location_id: location.id, lot_id: lot.id)).to eq(BigDecimal("5"))

    get "/pharmacy/lots/#{lot.id}/movements", params: { location_id: location.id }
    expect(response).to have_http_status(:ok)
    expect(json_body["movements"].map { |row| row["kind"] }).to eq(%w[loss transfer_out opening])

    get "/pharmacy/positions", params: { location_id: location.id }
    expect(response).to have_http_status(:ok)
    position = json_body["positions"].sole
    expect(position["item"]).to include("vector_product_id" => product.id, "item_kind" => "vector_control")
    expect(position["balance"]).to eq("5.00")
  end

  it "`POST /pharmacy/items/search` com `domain: vector_control` devolve o produto com `vector_product_id`; sem domínio, só CATMAT" do
    product
    vector_product!(code: "BTI", name: "Bti WG", active: false)
    sign_in_as(keeper)
    json_post "/pharmacy/items/search", q: "pyr", domain: "vector_control"
    expect(response).to have_http_status(:ok)
    expect(json_body["items"]).to eq([ { "catalog_item_id" => nil, "catmat_code" => nil, "vector_product_id" => product.id, "code" => "PYR",
                                         "item_kind" => "vector_control", "name" => "Pyriproxyfen 0,5% G", "unit" => "g",
                                         "dispensing_unit" => "g", "controlled" => false, "controlled_list" => nil } ])
    json_post "/pharmacy/items/search", q: "", domain: "vector_control"
    expect(json_body["items"].map { |item| item["code"] }).to eq([ "PYR" ])
    json_post "/pharmacy/items/search", q: "pyr", domain: "lab"
    expect([ response.status, json_body["path"] ]).to eq([ 422, "domain" ])

    pharmacy_city!
    json_post "/pharmacy/items/search", q: "losartana"
    expect(response).to have_http_status(:ok)
    expect(json_body["items"]).to all(include("catmat_code"))
    expect(json_body["items"].pluck("vector_product_id").compact).to be_empty
  end

  it "unidade UVZ com local não vira ubs → 409 unit_has_vector_control_location; com o local desativado, passa" do
    location
    sign_in_as(staff_with("admin-uvz-#{SecureRandom.hex(3)}@cidade.gov.br", "municipal_admin"))
    json_post "/attendance/units/#{uvz.id}", name: "UVZ Centro", kind: "ubs"
    expect([ response.status, json_body ]).to eq([ 409, { "error" => "unit_has_vector_control_location" } ])
    expect(uvz.reload.kind).to eq("environmental_surveillance")

    location.update!(active: false)
    json_post "/attendance/units/#{uvz.id}", name: "UVZ Centro", kind: "ubs"
    expect(response).to have_http_status(:ok)
  end

  it "a dispensação não lista o local: GET /pharmacy/locations traz o local só como estoque, e a dispensação nele → 403" do
    pharmacy_city!
    sign_in_as(keeper)
    get "/pharmacy/locations"
    expect(json_body["locations"]).to eq([ { "id" => location.id, "name" => "UVZ — insumos", "kind" => "vector_control",
                                             "health_unit" => { "id" => uvz.id, "name" => "UVZ Centro" }, "active" => true,
                                             "roles" => [ "stock_keeper" ] } ])
    json_post "/pharmacy/dispensations", location_id: location.id, prescription: { kind: "digital", id: SecureRandom.uuid }, items: []
    expect(response).to have_http_status(:forbidden)

    # O almoxarife do central de medicamentos não lê o local vector_control.
    central_keeper = pharmacy_staff!(central_location!, "stock_keeper")
    sign_in_as(central_keeper)
    get "/pharmacy/locations"
    expect(json_body["locations"].map { |row| row["id"] }).not_to include(location.id)
    get "/pharmacy/positions", params: { location_id: location.id }
    expect(response).to have_http_status(:forbidden)
  end
end
