require "rails_helper"

RSpec.describe "Endereço da unidade", type: :request do
  def body = JSON.parse(response.body)
  def status_and_error = [ response.status, body["error"] ]

  let(:admin) { staff_with("admin@cidade.gov.br", "municipal_admin") }
  let!(:centro) { Neighborhood.create!(name: "Centro", source: "seed") }
  let(:address) do
    { address_street: "Rua XV de Novembro", address_number: "500", address_complement: "sala 2",
      address_zip: "80020-310", neighborhood_id: centro.id }
  end

  before { sign_in_as(admin) }

  it "cria com endereço e as leituras devolvem os campos" do
    json_post "/attendance/units", { name: "UPA 24h Centro", kind: "upa" }.merge(address)
    expect(response).to have_http_status(:created)
    expected = { "address_street" => "Rua XV de Novembro", "address_number" => "500",
                 "address_complement" => "sala 2", "address_zip" => "80020310", "neighborhood_id" => centro.id }
    expect(body["unit"]).to include(expected)

    get "/attendance/units/all"
    expect(body["units"].sole).to include(expected)

    sign_in_as(staff_with("atendente@cidade.gov.br", "citizen_verifier"))
    get "/attendance/units"
    expect(body["units"].sole).to include(expected)
  end

  it "update sem as chaves de endereço preserva o endereço (dashboard anterior ao módulo 11)" do
    unit = create_unit("UBS Centro")
    unit.update!(address_street: "Rua XV de Novembro", address_zip: "80020310", neighborhood: centro)
    json_post "/attendance/units/#{unit.id}", name: "UBS Centro Renomeada", kind: "ubs"
    expect(response).to have_http_status(:ok)
    expect(unit.reload).to have_attributes(name: "UBS Centro Renomeada", address_street: "Rua XV de Novembro",
                                           address_zip: "80020310", neighborhood_id: centro.id)
  end

  it "null apaga o campo" do
    unit = create_unit("UBS Centro")
    unit.update!(address_complement: "sala 2", neighborhood: centro)
    json_post "/attendance/units/#{unit.id}", name: "UBS Centro", kind: "ubs", address_complement: nil, neighborhood_id: nil
    expect(unit.reload).to have_attributes(address_complement: nil, neighborhood_id: nil)
  end

  it "bairro inativo é aceito como localização (a spec só recusa inexistente)" do
    centro.update!(active: false)
    json_post "/attendance/units", name: "UBS Centro", kind: "ubs", neighborhood_id: centro.id
    expect(response).to have_http_status(:created)
  end

  describe "recusas (nada gravado)" do
    it "CEP fora de 8 dígitos ou não texto: 422 invalid_zip" do
      [ "1234", "8002031a", [ "80020310" ] ].each do |zip|
        json_post "/attendance/units", name: "UBS Nova", kind: "ubs", address_zip: zip
        expect(status_and_error).to eq([ 422, "invalid_zip" ]), zip.inspect
      end
      expect(HealthUnit.count).to eq(0)
    end

    it "bairro inexistente, id que não é UUID, ou não texto: 422 invalid_neighborhood" do
      unit = create_unit("UBS Centro")
      [ SecureRandom.uuid, "nao-e-uuid", { "id" => centro.id } ].each do |value|
        json_post "/attendance/units/#{unit.id}", name: "UBS Centro", kind: "ubs", neighborhood_id: value
        expect(status_and_error).to eq([ 422, "invalid_neighborhood" ]), value.inspect
      end
      expect(unit.reload.neighborhood_id).to be_nil
    end

    it "logradouro acima de 160: 422 invalid_unit" do
      json_post "/attendance/units", name: "UBS Nova", kind: "ubs", address_street: "x" * 161
      expect(status_and_error).to eq([ 422, "invalid_unit" ])
    end
  end
end
