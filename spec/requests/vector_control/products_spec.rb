require "rails_helper"

# Módulo 35a, Task 7 (ADR 0054; contrato §4, §12, §17; Q8, Q15): produtos de
# campo, só a coordenação. Código único sem caixa; usos não vazios; carga em
# texto com 2 casas; unidade e carga fixas depois do primeiro lote ou medida
# (409 product_in_use), nome, usos e ativo livres; evento só com ids.
RSpec.describe "Vigilância ambiental — produtos", type: :request do
  let!(:city) { vector_city! }
  let(:coordinator) { endemic_coordinator! }
  let(:input) { { code: "PYR", name: "Pyriproxyfen 0,5% G", unit: "g", charge_size: "2.00", uses: %w[focal], active: true } }

  def product_events = DomainEvent.where(name: "vector_product.changed")

  it "coordenação cria (201) com a forma VectorProduct; lista em { items }" do
    sign_in_as(coordinator)
    json_post "/vector_control/products", input.merge(charge_size: "0.5")
    expect(response).to have_http_status(:created)
    product = VectorProduct.sole
    expect(json_body).to eq("id" => product.id, "code" => "PYR", "name" => "Pyriproxyfen 0,5% G", "unit" => "g", "charge_size" => "0.50",
                            "uses" => [ "focal" ], "active" => true, "in_use" => false, "catmat_code" => nil)
    expect(product_events.map(&:payload)).to eq([ { "vector_product_id" => product.id, "user_id" => coordinator.id } ])

    get "/vector_control/products"
    expect(json_body).to eq("items" => [ json_body_of(product) ])
  end

  it "código repetido sem caixa → 422; uses vazio → 422 path uses" do
    sign_in_as(coordinator)
    json_post "/vector_control/products", input
    json_post "/vector_control/products", input.merge(code: "pyr")
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "code" } ])
    json_post "/vector_control/products", input.merge(code: "BTI", uses: [])
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "uses" } ])
    json_post "/vector_control/products", input.merge(code: "BTI", uses: %w[mechanical])
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "uses" } ])
    json_post "/vector_control/products", input.merge(code: "BTI", charge_size: 2)
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "charge_size" } ])
    json_post "/vector_control/products", input.merge(code: "BTI", charge_size: "0.00")
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "charge_size" } ])
    json_post "/vector_control/products", input.merge(code: "BTI", unit: "kg")
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "unit" } ])
    json_post "/vector_control/products", input.merge(code: "B" * 11)
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "code" } ])
    json_post "/vector_control/products", input.merge(code: "BTI", color: "red")
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "color" } ])
    json_post "/vector_control/products", input.except(:unit).merge(code: "BTI")
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "unit" } ])
    expect(VectorProduct.count).to eq(1)
  end

  it "mudar charge_size com lote → 409 product_in_use; mudar nome passa" do
    sign_in_as(coordinator)
    product = vector_product!(code: "PYR")
    json_patch "/vector_control/products/#{product.id}", charge_size: "3.00"
    expect(json_body).to include("charge_size" => "3.00", "in_use" => false)

    vector_lot!(vector_location!, product: product)
    json_patch "/vector_control/products/#{product.id}", charge_size: "4.00"
    expect([ response.status, json_body ]).to eq([ 409, { "error" => "product_in_use" } ])
    json_patch "/vector_control/products/#{product.id}", unit: "ml"
    expect([ response.status, json_body ]).to eq([ 409, { "error" => "product_in_use" } ])

    json_patch "/vector_control/products/#{product.id}", name: "Pyriproxyfen G", uses: %w[focal perifocal], active: false, charge_size: "3.00"
    expect(response).to have_http_status(:ok)
    expect(json_body).to include("name" => "Pyriproxyfen G", "uses" => %w[focal perifocal], "active" => false, "charge_size" => "3.00",
                                 "in_use" => true)
    expect(product.reload).to have_attributes(version: 3, charge_size: BigDecimal("3"), unit: "g")
  end

  it "o produto com medida também fica em uso (sem lote)" do
    product = vector_product!(code: "BTI")
    vector_visit!(product: product)
    sign_in_as(coordinator)
    json_patch "/vector_control/products/#{product.id}", charge_size: "9.00"
    expect([ response.status, json_body ]).to eq([ 409, { "error" => "product_in_use" } ])
  end

  it "fora da coordenação → 403 missing_role; id inexistente → 404" do
    sign_in_as(vector_lab!)
    get "/vector_control/products"
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
    sign_in_as(coordinator)
    json_patch "/vector_control/products/#{SecureRandom.uuid}", name: "X"
    expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
  end

  it "catmat_code grava e sobe a versão; null limpa; 0 → 422 path catmat_code; funciona com o bnafar desligado" do
    expect(Bnafar::Gate.usable?(city)).to be(false)
    sign_in_as(coordinator)
    json_post "/vector_control/products", input
    product = VectorProduct.sole
    version = product.version

    json_patch "/vector_control/products/#{product.id}", catmat_code: 452_345
    expect([ response.status, json_body["catmat_code"] ]).to eq([ 200, 452_345 ])
    expect(product.reload).to have_attributes(catmat_code: 452_345, version: version + 1)

    json_patch "/vector_control/products/#{product.id}", catmat_code: nil
    expect([ response.status, json_body["catmat_code"] ]).to eq([ 200, nil ])
    expect(product.reload).to have_attributes(catmat_code: nil, version: version + 2)

    [ 0, -1, "123", 1.5 ].each do |bad|
      json_patch "/vector_control/products/#{product.id}", catmat_code: bad
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "catmat_code" } ])
    end
    expect(product.reload.version).to eq(version + 2)
  end

  it "catmat_code já na criação" do
    sign_in_as(coordinator)
    json_post "/vector_control/products", input.merge(catmat_code: 99_001)
    expect([ response.status, json_body["catmat_code"] ]).to eq([ 201, 99_001 ])
  end

  def json_body_of(product)
    { "id" => product.id, "code" => product.code, "name" => product.name, "unit" => product.unit, "charge_size" => "0.50",
      "uses" => product.uses, "active" => product.active, "in_use" => false, "catmat_code" => nil }
  end
end
