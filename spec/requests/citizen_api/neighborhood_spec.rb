require "rails_helper"

RSpec.describe "Bairro do cidadão", type: :request do
  before do
    create_default_protocol!
    ConsentTerm.create!(version: "1", body: "Termo de teste", published_at: Time.current)
    sign_in_citizen("+5541998765432")
  end
  after { Rails.cache.clear }

  def body = JSON.parse(response.body)
  def status_and_error = [ response.status, body["error"] ]

  let!(:centro) { Neighborhood.create!(name: "Centro", source: "seed") }
  let!(:batel) { Neighborhood.create!(name: "Batel", source: "seed") }
  let!(:fechado) { Neighborhood.create!(name: "Ahu", source: "seed", active: false) }

  def start(params) = json_post("/citizen/conversations", { consent_version: "1" }.merge(params))
  def own_citizen(**attrs) = Citizen.create!({ cpf: "52998224725", phone: "+5541998765432" }.merge(attrs))

  it "lista só os bairros ativos, por nome" do
    get "/citizen/neighborhoods"
    expect(body).to eq("neighborhoods" => [ { "id" => batel.id, "name" => "Batel" }, { "id" => centro.id, "name" => "Centro" } ])
  end

  it "CPF novo com bairro: grava, a triagem copia, e people mostra" do
    start(cpf: "529.982.247-25", neighborhood_id: centro.id)
    expect(response).to have_http_status(:created)
    expect(Citizen.find(body["citizen_id"]).neighborhood).to eq(centro)
    expect(Triage.find(body.dig("step", "triage_id")).neighborhood_id).to eq(centro.id)

    get "/citizen/people"
    expect(body["people"].sole["neighborhood"]).to eq("id" => centro.id, "name" => "Centro")
  end

  it "prefiro não informar (null ou ausente): pessoa e triagem sem bairro" do
    start(cpf: "529.982.247-25", neighborhood_id: nil)
    expect(response).to have_http_status(:created)
    expect(Triage.find(body.dig("step", "triage_id")).neighborhood_id).to be_nil
    get "/citizen/people"
    expect(body["people"].sole["neighborhood"]).to be_nil
  end

  it "bairro inválido com CPF novo (inativo, inexistente, não UUID, lista): 422 e nenhum Citizen criado" do
    [ fechado.id, SecureRandom.uuid, "nao-e-uuid", [ centro.id ] ].each do |value|
      start(cpf: "529.982.247-25", neighborhood_id: value)
      expect(status_and_error).to eq([ 422, "invalid_neighborhood" ]), value.inspect
    end
    expect(Citizen.count).to eq(0)
  end

  it "termo desatualizado com bairro: 409 e nada gravado" do
    json_post "/citizen/conversations", cpf: "529.982.247-25", consent_version: "0", neighborhood_id: centro.id
    expect(response).to have_http_status(:conflict)
    expect(Citizen.count).to eq(0)
    expect(DomainEvent.where(name: "citizen.neighborhood_changed")).to be_empty
  end

  it "pessoa existente sem bairro: o bairro vem no início e é gravado" do
    citizen = own_citizen
    start(citizen_id: citizen.id, neighborhood_id: batel.id)
    expect(citizen.reload.neighborhood).to eq(batel)
    expect(Triage.find(body.dig("step", "triage_id")).neighborhood_id).to eq(batel.id)
  end

  it "pessoa que já tem bairro: outro bairro no início é ignorado; a triagem copia o que ela tinha" do
    citizen = own_citizen(neighborhood: centro)
    start(citizen_id: citizen.id, neighborhood_id: batel.id)
    expect(response).to have_http_status(:created)
    expect(citizen.reload.neighborhood).to eq(centro)
    expect(Triage.find(body.dig("step", "triage_id")).neighborhood_id).to eq(centro.id)
  end

  describe "POST /citizen/people/:id/neighborhood" do
    it "troca, publica o evento, e não muda a triagem antiga" do
      start(cpf: "529.982.247-25", neighborhood_id: centro.id)
      triage_id = body.dig("step", "triage_id")
      citizen_id = body["citizen_id"]

      json_post "/citizen/people/#{citizen_id}/neighborhood", neighborhood_id: batel.id
      expect(response).to have_http_status(:ok)
      expect(body["person"]).to include("id" => citizen_id, "neighborhood" => { "id" => batel.id, "name" => "Batel" })
      expect(Triage.find(triage_id).neighborhood_id).to eq(centro.id)
      expect(DomainEvent.where(name: "citizen.neighborhood_changed").order(:occurred_at).last.payload)
        .to eq("citizen_id" => citizen_id, "from_id" => centro.id, "to_id" => batel.id)
    end

    it "null apaga (prefiro não informar)" do
      citizen = own_citizen(neighborhood: centro)
      json_post "/citizen/people/#{citizen.id}/neighborhood", neighborhood_id: nil
      expect(body.dig("person", "neighborhood")).to be_nil
      expect(citizen.reload.neighborhood_id).to be_nil
    end

    it "bairro inativo, inexistente, não texto, ou sem a chave: 422 invalid_neighborhood" do
      citizen = own_citizen(neighborhood: centro)
      [ { neighborhood_id: fechado.id }, { neighborhood_id: SecureRandom.uuid }, { neighborhood_id: [ batel.id ] }, {} ]
        .each do |payload|
          json_post "/citizen/people/#{citizen.id}/neighborhood", payload
          expect(status_and_error).to eq([ 422, "invalid_neighborhood" ]), payload.inspect
        end
      expect(citizen.reload.neighborhood).to eq(centro)
    end

    it "CPF de outro telefone, ou id inexistente: 404" do
      other = Citizen.create!(cpf: "11144477735", phone: "+5541911112222")
      [ other.id, SecureRandom.uuid ].each do |id|
        json_post "/citizen/people/#{id}/neighborhood", neighborhood_id: batel.id
        expect(status_and_error).to eq([ 404, "not_found" ])
      end
      expect(other.reload.neighborhood_id).to be_nil
    end
  end

  it "sem sessão de cidadão: 401" do
    cookies.delete("citizen_session")
    get "/citizen/neighborhoods"
    expect(response).to have_http_status(:unauthorized)
  end
end
