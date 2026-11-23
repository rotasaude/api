require "rails_helper"

# Módulo 35b, Task 6 (ADR 0054; contrato §3, Q11, Q17): as peças do 35a que o
# centro de zoonoses usa — produtos, local de estoque, faltas de insumo,
# quarteirões, domínios e a busca de item do estoque — abrem com o
# `vector_control` OU o `zoonoses` utilizável (VectorControl::Gate.supplies_usable?);
# o resto do /vector_control segue só com o `vector_control`. Produto de
# zoonoses: uma finalidade só, `un`, carga 1.00, e só com o zoonoses
# utilizável. O vector_control_domains.products (enum da v1.3.0) nunca lista
# a vacina nem a coleira. A falta de uma dose aparece na tela de faltas do 35a
# com a origem.
RSpec.describe "Zoonoses — peças do 35a", type: :request do
  let!(:city) { zoonoses_city! }
  let(:coordinator) { endemic_coordinator! }
  let(:location) { vector_location!(name: "UVZ — insumos") }
  let(:neighborhood) { Neighborhood.create!(name: "Centro #{SecureRandom.hex(3)}", source: "manual") }
  let(:vaccine_input) { { code: "VAR", name: "Vacina antirrábica animal", unit: "un", charge_size: "1.00", uses: %w[rabies_vaccine] } }

  def json_put(path, params = {}) = put(path, params: params.to_json, headers: { "CONTENT_TYPE" => "application/json" })
  def switch!(key, enabled)
    Platform::Features.set!(city: city, key: key, enabled: enabled, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
  end

  # [status, corpo] das rotas das peças, na ordem.
  def supply_routes(keeper)
    sign_in_as(coordinator)
    calls = []
    get "/vector_control/products"
    calls << response.status
    json_post "/vector_control/products", vaccine_input
    calls << response.status
    get "/vector_control/settings"
    calls << response.status
    json_put "/vector_control/settings", stock_location_id: location.id
    calls << response.status
    get "/vector_control/stock_shortfalls"
    calls << response.status
    get "/vector_control/blocks", params: { neighborhood_id: neighborhood.id }
    calls << response.status
    json_post "/vector_control/blocks", neighborhood_id: neighborhood.id, number: "12"
    calls << response.status
    get "/vector_control/domains"
    calls << response.status
    sign_in_as(keeper)
    json_post "/pharmacy/items/search", q: "", domain: "vector_control"
    calls << response.status
    calls
  end

  it "cidade só com zoonoses: produtos, settings, faltas, quarteirões, domínios e a busca de item → 200/201; /vector_control/ovitraps → 403 feature_disabled" do
    expect(VectorControl::Gate.usable?(city)).to be(false)
    keeper = vector_keeper!(location)
    expect(supply_routes(keeper)).to eq([ 200, 201, 200, 200, 200, 200, 201, 200, 200 ])
    expect(json_body["items"].map { _1["code"] }).to eq([ "VAR" ])
    expect(VectorControlSetting.find(1).stock_location_id).to eq(location.id)

    sign_in_as(coordinator)
    get "/vector_control/ovitraps"
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "vector_control" } ])
    get "/vector_control/cadences"
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "vector_control" } ])
  end

  it "sem os dois gates → 403 feature_disabled nessas rotas" do
    keeper = vector_keeper!(location)
    switch!(Zoonoses::Gate::KEY, false)
    expect(supply_routes(keeper)).to eq([ 403 ] * 9)
    expect(json_body).to eq("error" => "feature_disabled", "feature" => "vector_control")
    expect(VectorProduct.count).to eq(0)
  end

  it "produto rabies_vaccine com unit g → 422 path uses; com focal junto → 422 path uses; sem zoonoses utilizável → 422 path uses" do
    sign_in_as(coordinator)
    json_post "/vector_control/products", vaccine_input.merge(unit: "g")
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "uses" } ])
    json_post "/vector_control/products", vaccine_input.merge(charge_size: "2.00")
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "uses" } ])
    json_post "/vector_control/products", vaccine_input.merge(uses: %w[rabies_vaccine focal])
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "uses" } ])
    json_post "/vector_control/products", vaccine_input.merge(uses: %w[rabies_vaccine collar])
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "uses" } ])

    json_post "/vector_control/products", vaccine_input.merge(uses: %w[collar], code: "COL")
    expect(response).to have_http_status(:created)
    collar = VectorProduct.sole
    patch "/vector_control/products/#{collar.id}", params: { unit: "g" }.to_json, headers: { "CONTENT_TYPE" => "application/json" }
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "uses" } ])
    patch "/vector_control/products/#{collar.id}", params: { name: "Coleira 4%" }.to_json, headers: { "CONTENT_TYPE" => "application/json" }
    expect([ response.status, json_body["name"] ]).to eq([ 200, "Coleira 4%" ])

    # Cidade com o vector_control e sem o zoonoses: a finalidade de zoonoses é recusada.
    switch!(VectorControl::Gate::KEY, true)
    switch!(Zoonoses::Gate::KEY, false)
    json_post "/vector_control/products", vaccine_input
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "uses" } ])
    json_post "/vector_control/products", vaccine_input.merge(unit: "g", charge_size: "2.00", uses: %w[focal])
    expect(response).to have_http_status(:created)
    expect(VectorProduct.count).to eq(2)
  end

  it "PATCH nunca troca a família do produto: coleira → focal e focal un/1.00 → rabies_vaccine → 422 path uses; focal → perifocal segue" do
    switch!(VectorControl::Gate::KEY, true)
    collar = zoonoses_product!(code: "COL", use: "collar")
    focal = vector_product!(code: "PYR", unit: "un", charge_size: "1.00", uses: %w[focal])
    sign_in_as(coordinator)
    patch_product = ->(product, body) { patch "/vector_control/products/#{product.id}", params: body.to_json, headers: { "CONTENT_TYPE" => "application/json" } }

    patch_product.call(collar, uses: %w[focal])
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "uses" } ])
    patch_product.call(collar, uses: %w[rabies_vaccine])
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "uses" } ])
    patch_product.call(collar, uses: %w[collar], unit: "g")
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "uses" } ])
    patch_product.call(focal, uses: %w[rabies_vaccine])
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "uses" } ])
    expect([ collar.reload.uses, focal.reload.uses ]).to eq([ %w[collar], %w[focal] ])

    patch_product.call(focal, uses: %w[perifocal])
    expect([ response.status, json_body["uses"] ]).to eq([ 200, %w[perifocal] ])
    patch_product.call(collar, uses: %w[collar], name: "Coleira 4%")
    expect([ response.status, json_body["name"] ]).to eq([ 200, "Coleira 4%" ])
  end

  it "GET /vector_control/domains numa cidade com os dois gates não lista a vacina (o corpo valida contra o reference-response v1.3.0)" do
    switch!(VectorControl::Gate::KEY, true)
    vector = vector_product!(code: "PYR", charge_size: "1.00")
    zoonoses_product!(code: "VAR")
    zoonoses_product!(code: "COL", use: "collar")
    sign_in_as(coordinator)

    get "/vector_control/domains"
    expect(response).to have_http_status(:ok)
    expect(json_body["products"].map { _1["id"] }).to eq([ vector.id ])
    raw = File.binread(FieldSync::Schemas::DIR.join("reference-response-v1.json"))
    schemer = JSONSchemer.schema(JSON.parse(raw)).ref("#/$defs/vector_control_domains")
    expect(schemer.validate(json_body).map { |error| error.fetch("error") }).to eq([])
  end

  it "a coordenação concilia a falta de uma dose; a linha traz source: vaccination, occurred_on = vaccinated_on e visit_on: null" do
    vaccine = zoonoses_product!(code: "VAR")
    dose = rabies_vaccination!(product: vaccine, vaccinated_on: Time.zone.today - 3)
    shortfall = Zoonoses::ApplyStock.call(document: dose, product_id: vaccine.id, kind: "animal_vaccination", by: coordinator,
                                          today: Time.zone.today).payload.fetch(:shortfall)
    sign_in_as(coordinator)

    get "/vector_control/stock_shortfalls"
    expect(json_body["items"]).to eq([ { "id" => shortfall.id, "created_at" => shortfall.created_at.utc.iso8601(6), "stock_location" => nil,
                                         "product" => { "id" => vaccine.id, "code" => "VAR", "name" => "Vacina antirrábica animal", "unit" => "un" },
                                         "quantity" => "1.00", "cause" => "no_location", "source" => "vaccination",
                                         "occurred_on" => (Time.zone.today - 3).iso8601, "visit_on" => nil,
                                         "reconciled_at" => nil, "reconciled_by" => nil } ])

    json_post "/vector_control/stock_shortfalls/#{shortfall.id}/reconcile", note: "dose reposta pela regional"
    expect(response).to have_http_status(:ok)
    expect(json_body).to include("id" => shortfall.id, "source" => "vaccination", "visit_on" => nil)
    expect(json_body["reconciled_at"]).to be_present
    expect(shortfall.reload.reconciled_by_user_id).to eq(coordinator.id)
  end
end
