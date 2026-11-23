require "rails_helper"

# Módulo 35a, Task 7 (ADR 0054; contrato §4, §12; Q8, Q9; W-6): as faltas de
# insumo. A coordenação lê todas, inclusive no_location; o stock_keeper só as
# do seu local. Conciliação com nota 10–500; a do sistema (estorno na
# retirada) sai com reconciled_by: null. Sem pessoa.
RSpec.describe "Vigilância ambiental — faltas de insumo", type: :request do
  let!(:city) { vector_city! }
  let(:coordinator) { endemic_coordinator! }
  let(:product) { vector_product!(code: "PYR", name: "Pyriproxyfen") }
  let(:location) { vector_location!(name: "UVZ — insumos") }
  let(:agent) { endemic_agent! }

  before { allow(Ledi::DeliverJob).to receive(:perform_later) }

  def shortfall_at(target)
    vector_stock_location!(target)
    vector_shortfall!(product: product, agent: agent)
  end

  it "coordenação vê a no_location; stock_keeper vê só a do seu local e recebe 403 com outro location_id" do
    without = shortfall_at(nil)
    here = shortfall_at(location)
    other_location = vector_location!
    there = shortfall_at(other_location)
    keeper = vector_keeper!(location)

    sign_in_as(coordinator)
    get "/vector_control/stock_shortfalls"
    expect(json_body["items"].map { |row| row["id"] }).to eq([ there.id, here.id, without.id ])
    expect(json_body["next_before"]).to be_nil
    row = json_body["items"].last
    expect(row).to eq("id" => without.id, "created_at" => without.created_at.utc.iso8601(6), "stock_location" => nil,
                      "product" => { "id" => product.id, "code" => "PYR", "name" => "Pyriproxyfen", "unit" => "g" },
                      "quantity" => "2.00", "cause" => "no_location", "source" => "inspection",
                      "occurred_on" => Time.zone.today.iso8601, "visit_on" => Time.zone.today.iso8601,
                      "reconciled_at" => nil, "reconciled_by" => nil)
    get "/vector_control/stock_shortfalls", params: { location_id: location.id }
    expect(json_body["items"].map { |item| item["id"] }).to eq([ here.id ])

    sign_in_as(keeper)
    get "/vector_control/stock_shortfalls"
    expect(json_body["items"].map { |item| item["id"] }).to eq([ here.id ])
    expect(json_body["items"].sole["stock_location"]).to eq("id" => location.id, "name" => "UVZ — insumos")
    get "/vector_control/stock_shortfalls", params: { location_id: other_location.id }
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])

    sign_in_as(vector_lab!)
    get "/vector_control/stock_shortfalls"
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
  end

  it "conciliação sem nota → 422 invalid_request path note; com nota, reconciled_by com o nome; repetida → 409" do
    shortfall = shortfall_at(location)
    sign_in_as(coordinator)
    json_post "/vector_control/stock_shortfalls/#{shortfall.id}/reconcile", {}
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "note" } ])
    json_post "/vector_control/stock_shortfalls/#{shortfall.id}/reconcile", note: "curta"
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "note" } ])

    json_post "/vector_control/stock_shortfalls/#{shortfall.id}/reconcile", note: "lote achado no depósito"
    expect(response).to have_http_status(:ok)
    expect(json_body).to include("id" => shortfall.id, "reconciled_by" => { "name" => coordinator.professional&.professional_name })
    expect(json_body["reconciled_at"]).to be_present
    expect(response.body).not_to include("lote achado")

    json_post "/vector_control/stock_shortfalls/#{shortfall.id}/reconcile", note: "lote achado no depósito"
    expect([ response.status, json_body ]).to eq([ 409, { "error" => "already_reconciled" } ])

    get "/vector_control/stock_shortfalls", params: { state: "reconciled" }
    expect(json_body["items"].map { |row| row["id"] }).to eq([ shortfall.id ])
    get "/vector_control/stock_shortfalls"
    expect(json_body["items"]).to eq([])
  end

  it "a do sistema sai com `reconciled_by: null`" do
    vector_stock_location!(location)
    visit = vector_visit!(product: product, agent: agent)
    expect(HomeVisits::Withdraw.call(visit, by: agent, expected_state: "recorded", reason: "registrada no imóvel errado")).to be_ok

    sign_in_as(coordinator)
    get "/vector_control/stock_shortfalls", params: { state: "reconciled" }
    row = json_body["items"].sole
    expect(row["reconciled_at"]).to be_present
    expect(row["reconciled_by"]).to be_nil
  end

  it "estado fora da lista e chave estranha na query → 422" do
    sign_in_as(coordinator)
    get "/vector_control/stock_shortfalls", params: { state: "all" }
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "state" } ])
    get "/vector_control/stock_shortfalls", params: { cause: "no_lot" }
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request" } ])
  end
end
