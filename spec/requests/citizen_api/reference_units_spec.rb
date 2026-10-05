require "rails_helper"

RSpec.describe "Unidade de referência do cidadão", type: :request do
  before do
    create_default_protocol!
    ConsentTerm.create!(version: "1", body: "Termo de teste", published_at: Time.current)
    sign_in_citizen("+5541998765432")
    [ ubs, upa, fechada ].each { |u| NeighborhoodCoverage.create!(neighborhood: centro, health_unit: u) }
  end
  after { Rails.cache.clear }

  def body = JSON.parse(response.body)

  let!(:centro) { Neighborhood.create!(name: "Centro", source: "seed") }
  let!(:batel) { Neighborhood.create!(name: "Batel", source: "seed") }
  let!(:ubs) do
    create_unit("UBS Centro").tap do |u|
      u.update!(address_street: "Rua XV de Novembro", address_number: "500", address_zip: "80020310", neighborhood: centro)
    end
  end
  let!(:upa) { create_unit("UPA 24h", kind: "upa") }
  let!(:fechada) { create_unit("UBS Antiga", active: false) }

  def start_triage(neighborhood_id)
    start_citizen_triage(neighborhood_id: neighborhood_id)
    { triage_id: body.dig("step", "triage_id"), citizen_id: body["citizen_id"] }
  end

  it "GET /citizen/triages/:id traz as unidades ativas que cobrem o bairro da triagem, por nome" do
    ids = start_triage(centro.id)
    get "/citizen/triages/#{ids[:triage_id]}"
    expect(body["reference_units"]).to eq([
      { "id" => ubs.id, "name" => "UBS Centro", "kind" => "ubs",
        "address" => { "street" => "Rua XV de Novembro", "number" => "500", "complement" => nil, "zip" => "80020310" } },
      { "id" => upa.id, "name" => "UPA 24h", "kind" => "upa",
        "address" => { "street" => nil, "number" => nil, "complement" => nil, "zip" => nil } }
    ])
  end

  it "sem bairro: lista vazia" do
    ids = start_triage(nil)
    get "/citizen/triages/#{ids[:triage_id]}"
    expect(body["reference_units"]).to eq([])
  end

  it "trocar o bairro depois não muda a referência da triagem antiga" do
    ids = start_triage(centro.id)
    json_post "/citizen/people/#{ids[:citizen_id]}/neighborhood", neighborhood_id: batel.id
    get "/citizen/triages/#{ids[:triage_id]}"
    expect(body["reference_units"].map { |u| u["id"] }).to eq([ ubs.id, upa.id ])
  end

  it "unidade desativada depois: some da referência" do
    ids = start_triage(centro.id)
    upa.update!(active: false)
    get "/citizen/triages/#{ids[:triage_id]}"
    expect(body["reference_units"].map { |u| u["id"] }).to eq([ ubs.id ])
  end

  # Decisão do usuário (2026-09-28): o relatório público (link sem login) não
  # mostra a unidade de referência nem nada de bairro.
  it "o relatório público GET /r/:token não traz reference_units nem bairro" do
    ids = start_triage(centro.id)
    triage = Triage.find(ids[:triage_id])
    token = ReportSnapshot.mint_token
    ReportSnapshot.create!(triage: triage, protocol_definition: triage.protocol_definition,
                           outcome: { "tier" => "alta" }, payload: { "tier" => "alta", "priority" => 1 },
                           token: token, signature: ReportSnapshot.sign(token), expires_at: 30.days.from_now)

    get "/r/#{token}"
    expect(response).to have_http_status(:ok)
    expect(body.keys).not_to include("reference_units")
    expect(response.body).not_to match(/reference_units|neighborhood/)
    expect(response.body).not_to include(centro.id, "Centro", ubs.id, "UBS Centro")
  end
end
