require "rails_helper"

# Módulo 35a, Task 7 (ADR 0054; contrato §4, §12; Q8): o local de onde o
# boletim baixa, só a coordenação; um local vector_control ativo ou nulo.
RSpec.describe "Vigilância ambiental — ajustes do estoque", type: :request do
  let!(:city) { vector_city! }
  let(:coordinator) { endemic_coordinator! }

  it "local de farmácia → 422 path stock_location_id" do
    pharmacy = StockLocation.create!(kind: "central", name: "Central #{SecureRandom.hex(2)}", updated_by_user: coordinator)
    inactive = vector_location!.tap { |location| location.update!(active: false) }
    sign_in_as(coordinator)
    [ pharmacy.id, inactive.id, SecureRandom.uuid, "x" ].each do |id|
      json_put "/vector_control/settings", stock_location_id: id
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "stock_location_id" } ])
    end
    json_put "/vector_control/settings", {}
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "stock_location_id" } ])
    expect(VectorControlSetting.find_by(id: 1)&.stock_location_id).to be_nil
  end

  it "GET traz `options` só com locais vector_control; PUT escolhe e volta a nulo" do
    location = vector_location!(name: "UVZ — insumos")
    vector_location!.update!(active: false)
    StockLocation.create!(kind: "central", name: "Central #{SecureRandom.hex(2)}", updated_by_user: coordinator)
    sign_in_as(coordinator)

    get "/vector_control/settings"
    expect(json_body).to eq("stock_location" => nil, "options" => [ { "id" => location.id, "name" => "UVZ — insumos" } ])

    json_put "/vector_control/settings", stock_location_id: location.id
    expect(json_body).to eq("stock_location" => { "id" => location.id, "name" => "UVZ — insumos" },
                            "options" => [ { "id" => location.id, "name" => "UVZ — insumos" } ])
    expect(VectorControlSetting.find(1)).to have_attributes(stock_location_id: location.id, version: 2)

    json_put "/vector_control/settings", stock_location_id: nil
    expect(json_body["stock_location"]).to be_nil
    expect(VectorControlSetting.find(1)).to have_attributes(stock_location_id: nil, version: 3)
  end

  it "fora da coordenação → 403 missing_role" do
    sign_in_as(vector_lab!)
    get "/vector_control/settings"
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
  end
end
