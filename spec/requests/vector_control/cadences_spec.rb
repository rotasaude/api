require "rails_helper"

# Módulo 35a (contrato §5, §12; Q8): a cadência por (bairro, risco, PE). Só a
# coordenação; o PUT `{ items }` troca a lista inteira, com step-up.
RSpec.describe "Vigilância ambiental — cadências", type: :request do
  let!(:city) { vector_city! }
  let(:coordinator) { endemic_coordinator! }
  let(:neighborhood) { Neighborhood.create!(name: "Centro #{SecureRandom.hex(3)}", source: "manual") }

  def item(days:, neighborhood_id: nil, risk_class: nil, strategic_point: false)
    { neighborhood_id: neighborhood_id, risk_class: risk_class, strategic_point: strategic_point, days: days }
  end

  def put_items(items) = json_put("/vector_control/cadences", items: items)

  it "PUT sem step-up → 401 mfa_required; com → 200 e a lista trocada" do
    VectorCadence.create!(days: 50)
    kept = VectorCadence.create!(neighborhood: neighborhood, risk_class: "red", days: 30)
    VectorCadence.create!(strategic_point: true, days: 12)

    sign_in_as(coordinator)
    put_items([ item(days: 45) ])
    expect([ response.status, json_body ]).to eq([ 401, { "error" => "mfa_required" } ])
    expect(VectorCadence.count).to eq(3)

    stepped_up!(coordinator)
    list = [ item(days: 20, neighborhood_id: neighborhood.id, risk_class: "red"), item(days: 15, strategic_point: true),
             item(days: 40, risk_class: "red") ]
    put_items(list)
    expect(response).to have_http_status(:ok)
    expect(json_body).to eq("items" => [
      { "neighborhood_id" => nil, "risk_class" => "red", "strategic_point" => false, "days" => 40 },
      { "neighborhood_id" => nil, "risk_class" => nil, "strategic_point" => true, "days" => 15 },
      { "neighborhood_id" => neighborhood.id, "risk_class" => "red", "strategic_point" => false, "days" => 20 }
    ])
    expect(VectorCadence.count).to eq(3)
    expect(kept.reload).to have_attributes(days: 20, version: 2)

    get "/vector_control/cadences"
    expect(json_body["items"].size).to eq(3)
    put_items([])
    expect(json_body).to eq("items" => [])
    expect(VectorCadence.count).to eq(0)
  end

  it "recusas: dias fora de 7–365, linha repetida, PE com risco, bairro desconhecido; nada muda" do
    VectorCadence.create!(days: 50)
    stepped_up!(coordinator)
    [
      [ [ item(days: 60), item(days: 6, risk_class: "red") ], "items[1].days" ],
      [ [ item(days: 366) ], "items[0].days" ],
      [ [ item(days: "30") ], "items[0].days" ],
      [ [ item(days: 60), item(days: 30) ], "items[1]" ],
      [ [ item(days: 10, strategic_point: true, risk_class: "red") ], "items[0].risk_class" ],
      [ [ item(days: 10, risk_class: "blue") ], "items[0].risk_class" ],
      [ [ item(days: 10, neighborhood_id: SecureRandom.uuid) ], "items[0].neighborhood_id" ],
      [ [ item(days: 10).except(:strategic_point) ], "items[0].strategic_point" ],
      [ [ item(days: 10).merge(note: "x") ], "items[0].note" ],
      [ { "days" => 10 }, "items" ]
    ].each do |items, path|
      put_items(items)
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => path } ])
    end
    expect(VectorCadence.pluck(:days)).to eq([ 50 ])
  end

  it "só a coordenação: agente e laboratório → 403 missing_role" do
    [ endemic_agent!, vector_lab! ].each do |user|
      sign_in_as(user)
      get "/vector_control/cadences"
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
    end
  end
end
