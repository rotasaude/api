require "rails_helper"

# Módulo 35a (ADR 0054; contrato §2, §12, §17; Q8): quarteirões e vizinhos.
# A coordenação escreve; o agente de endemias e o vector_lab só leem. Número
# único sem caixa no bairro; vizinho guardado uma vez e só desfeito
# (ended_at), com os dois quarteirões reemitidos; evento só com ids.
RSpec.describe "Vigilância ambiental — quarteirões", type: :request do
  let!(:city) { vector_city! }
  let(:coordinator) { endemic_coordinator! }
  let(:neighborhood) { Neighborhood.create!(name: "Centro #{SecureRandom.hex(3)}", source: "manual") }
  let(:other_neighborhood) { Neighborhood.create!(name: "Batel #{SecureRandom.hex(3)}", source: "manual") }

  def json_delete_body(path) = delete(path, params: "{}", headers: { "CONTENT_TYPE" => "application/json" })
  def block_events = DomainEvent.where(name: "city_block.changed").order(:occurred_at)

  it "coordenação cria (201), número repetido sem caixa → 422 block_number_taken" do
    sign_in_as(coordinator)
    json_post "/vector_control/blocks", neighborhood_id: neighborhood.id, number: "12-A"
    expect(response).to have_http_status(:created)
    block = CityBlock.sole
    expect(json_body).to eq("id" => block.id, "neighborhood" => { "id" => neighborhood.id, "name" => neighborhood.name },
                            "number" => "12-A", "active" => true, "neighbor_ids" => [], "households_count" => 0, "version" => 1)

    json_post "/vector_control/blocks", neighborhood_id: neighborhood.id, number: "12-a"
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "block_number_taken", "path" => "number" } ])
    json_post "/vector_control/blocks", neighborhood_id: other_neighborhood.id, number: "12-a"
    expect(response).to have_http_status(:created)

    other = city_block!(neighborhood: neighborhood, number: "13")
    json_patch "/vector_control/blocks/#{other.id}", number: "12-A"
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "block_number_taken", "path" => "number" } ])
  end

  it "número `12 A` → 422 invalid_request path number" do
    sign_in_as(coordinator)
    json_post "/vector_control/blocks", neighborhood_id: neighborhood.id, number: "12 A"
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "number" } ])
    json_post "/vector_control/blocks", neighborhood_id: "nb1", number: "12"
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "neighborhood_id" } ])
    json_post "/vector_control/blocks", neighborhood_id: neighborhood.id, number: "12", color: "red"
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "color" } ])
    expect(CityBlock.count).to eq(0)
  end

  it "vizinho de si mesmo → 422 invalid_neighbor; vizinho repetido é idempotente" do
    sign_in_as(coordinator)
    block = city_block!(neighborhood: neighborhood, number: "1")
    neighbor = city_block!(neighborhood: other_neighborhood, number: "1")
    json_post "/vector_control/blocks/#{block.id}/neighbors", neighbor_block_id: block.id
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_neighbor", "path" => "neighbor_block_id" } ])

    json_post "/vector_control/blocks/#{block.id}/neighbors", neighbor_block_id: neighbor.id
    expect(response).to have_http_status(:ok)
    expect(json_body).to include("id" => block.id, "neighbor_ids" => [ neighbor.id ], "version" => 2)
    expect(neighbor.reload.version).to eq(2)
    json_post "/vector_control/blocks/#{block.id}/neighbors", neighbor_block_id: neighbor.id
    expect(response).to have_http_status(:ok)
    expect(json_body).to include("neighbor_ids" => [ neighbor.id ], "version" => 2)
    expect(CityBlockNeighbor.count).to eq(1)

    get "/vector_control/blocks", params: { neighborhood_id: other_neighborhood.id }
    expect(json_body["items"].sole).to include("id" => neighbor.id, "neighbor_ids" => [ block.id ])
  end

  it "DELETE do vizinho grava ended_at e reemite os dois (version + 1)" do
    sign_in_as(coordinator)
    block = city_block!(neighborhood: neighborhood, number: "1")
    neighbor = city_block!(neighborhood: neighborhood, number: "2")
    pair = CityBlockNeighbor.create!(city_block: [ block, neighbor ].min_by(&:id), neighbor_block: [ block, neighbor ].max_by(&:id))

    json_delete_body "/vector_control/blocks/#{block.id}/neighbors/#{neighbor.id}"
    expect(response).to have_http_status(:ok)
    expect(json_body).to include("id" => block.id, "neighbor_ids" => [], "version" => 2)
    expect(pair.reload.ended_at).to be_present
    expect(neighbor.reload.version).to eq(2)
    expect(block_events.map { |event| event.payload["city_block_id"] }).to contain_exactly(block.id, neighbor.id)

    json_post "/vector_control/blocks/#{neighbor.id}/neighbors", neighbor_block_id: block.id
    expect(json_body).to include("neighbor_ids" => [ block.id ], "version" => 3)
    expect(CityBlockNeighbor.current.count).to eq(1)
    expect(CityBlockNeighbor.count).to eq(2)
  end

  it "desativar com imóvel ativo → 409 block_in_use" do
    sign_in_as(coordinator)
    block = city_block!(neighborhood: neighborhood, number: "1")
    household = registry_household!(micro_area: registry_micro_area!(code: "01"), neighborhood_id: neighborhood.id)
    vector_profile!(household, block: block)

    json_patch "/vector_control/blocks/#{block.id}", active: false
    expect([ response.status, json_body ]).to eq([ 409, { "error" => "block_in_use" } ])
    expect(block.reload.active).to be(true)

    household.update_columns(status: "inactive")
    json_patch "/vector_control/blocks/#{block.id}", active: false
    expect(response).to have_http_status(:ok)
    expect(json_body).to include("active" => false, "households_count" => 0, "version" => 2)
    json_patch "/vector_control/blocks/#{block.id}", active: "no"
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "active" } ])
  end

  it "agente e vector_lab leem, não escrevem (403 missing_role)" do
    block = city_block!(neighborhood: neighborhood, number: "1")
    [ endemic_agent!, vector_lab! ].each do |reader|
      sign_in_as(reader)
      get "/vector_control/blocks", params: { neighborhood_id: neighborhood.id }
      expect(response).to have_http_status(:ok)
      expect(json_body).to eq("items" => [ { "id" => block.id, "neighborhood" => { "id" => neighborhood.id, "name" => neighborhood.name },
                                             "number" => "1", "active" => true, "neighbor_ids" => [], "households_count" => 0,
                                             "version" => 1 } ],
                              "next_before" => nil)

      json_post "/vector_control/blocks", neighborhood_id: neighborhood.id, number: "2"
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
      json_patch "/vector_control/blocks/#{block.id}", active: false
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
    end

    sign_in_as(field_agent!) # ACS: nem lê
    get "/vector_control/blocks", params: { neighborhood_id: neighborhood.id }
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
    expect(CityBlock.count).to eq(1)
  end

  it "lista pede o bairro e só aceita as chaves dela" do
    sign_in_as(coordinator)
    get "/vector_control/blocks"
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "neighborhood_id" } ])
    get "/vector_control/blocks", params: { neighborhood_id: neighborhood.id, name: "x" }
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request" } ])
    json_post "/vector_control/blocks?number=1", neighborhood_id: neighborhood.id, number: "1"
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request" } ])
  end

  it "interruptor desligado → 403 feature_disabled" do
    Platform::Features.set!(city: city, key: VectorControl::Gate::KEY, enabled: false, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
    sign_in_as(coordinator)
    get "/vector_control/blocks", params: { neighborhood_id: neighborhood.id }
    expect(response).to have_http_status(:forbidden)
    expect(json_body["error"]).to eq("feature_disabled")
    json_post "/vector_control/blocks", neighborhood_id: neighborhood.id, number: "1"
    expect(response).to have_http_status(:forbidden)
    expect(CityBlock.count).to eq(0)
  end

  it "evento `city_block.changed` só com `city_block_id` e `user_id`" do
    sign_in_as(coordinator)
    json_post "/vector_control/blocks", neighborhood_id: neighborhood.id, number: "7"
    block_id = json_body["id"]
    json_patch "/vector_control/blocks/#{block_id}", number: "7-B"
    expect(json_body).to include("number" => "7-B", "version" => 2)
    expect(block_events.map(&:payload)).to eq([ { "city_block_id" => block_id, "user_id" => coordinator.id } ] * 2)
  end
end
