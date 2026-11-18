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

  # Q35: o PUT leva o digest da lista que a tela leu (aqui, um GET antes).
  def current_digest
    get "/vector_control/cadences"
    json_body.fetch("digest")
  end

  def put_items(items, expected_digest: current_digest)
    json_put("/vector_control/cadences", { items: items, expected_digest: expected_digest }.compact)
  end

  def stored = VectorCadence.order(:days).pluck(:neighborhood_id, :risk_class, :strategic_point, :days, :version)

  it "PUT sem step-up → 401 mfa_required; com → 200 e a lista trocada" do
    VectorCadence.create!(days: 50)
    kept = VectorCadence.create!(neighborhood: neighborhood, risk_class: "red", days: 30)
    VectorCadence.create!(strategic_point: true, days: 12)

    sign_in_as(coordinator)
    put_items([ item(days: 45) ], expected_digest: "0" * 64)
    expect([ response.status, json_body ]).to eq([ 401, { "error" => "mfa_required" } ])
    expect(VectorCadence.count).to eq(3)

    stepped_up!(coordinator)
    list = [ item(days: 20, neighborhood_id: neighborhood.id, risk_class: "red"), item(days: 15, strategic_point: true),
             item(days: 40, risk_class: "red") ]
    put_items(list)
    expect(response).to have_http_status(:ok)
    expect(json_body.except("digest")).to eq("items" => [
      { "neighborhood_id" => nil, "risk_class" => "red", "strategic_point" => false, "days" => 40 },
      { "neighborhood_id" => nil, "risk_class" => nil, "strategic_point" => true, "days" => 15 },
      { "neighborhood_id" => neighborhood.id, "risk_class" => "red", "strategic_point" => false, "days" => 20 }
    ])
    expect(VectorCadence.count).to eq(3)
    expect(kept.reload).to have_attributes(days: 20, version: 2)

    get "/vector_control/cadences"
    expect(json_body["items"].size).to eq(3)
    put_items([])
    expect(json_body.except("digest")).to eq("items" => [])
    expect(VectorCadence.count).to eq(0)
  end

  describe "digest da lista (Q35)" do
    let(:empty) { Digest::SHA256.hexdigest("[]") }

    before { stepped_up!(coordinator) }

    it "GET traz o digest; o PUT devolve o novo, igual ao de um GET em seguida" do
      get "/vector_control/cadences"
      expect(json_body).to eq("items" => [], "digest" => empty)

      put_items([ item(days: 40, risk_class: "red"), item(days: 15, strategic_point: true) ], expected_digest: empty)
      expect(response).to have_http_status(:ok)
      saved = json_body.fetch("digest")
      expect(saved).to match(/\A[0-9a-f]{64}\z/)
      expect(saved).not_to eq(empty)

      get "/vector_control/cadences"
      expect(json_body.fetch("digest")).to eq(saved)
    end

    it "dois PUTs com o mesmo digest: o segundo → 409 cadences_changed, nada gravado nem publicado" do
      VectorCadence.create!(days: 50)
      read = current_digest

      put_items([ item(days: 40) ], expected_digest: read)
      expect(response).to have_http_status(:ok)
      before = stored
      events = DomainEvent.count

      put_items([ item(days: 30, risk_class: "red") ], expected_digest: read)
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "cadences_changed" } ])
      expect(stored).to eq(before)
      expect(stored).to eq([ [ nil, nil, false, 40, 2 ] ])
      expect(DomainEvent.count).to eq(events)
    end

    it "lista vazia sobre lista vazia passa" do
      put_items([], expected_digest: empty)
      expect([ response.status, json_body ]).to eq([ 200, { "items" => [], "digest" => empty } ])
    end

    it "sem expected_digest → 422 expected_digest_required; fora de 64 hex minúsculos → 422 invalid_request" do
      VectorCadence.create!(days: 50)
      put_items([ item(days: 40) ], expected_digest: nil)
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "expected_digest_required", "path" => "expected_digest" } ])

      [ current_digest.upcase, "abc", 42, "g" * 64, "#{current_digest}0" ].each do |bad|
        put_items([ item(days: 40) ], expected_digest: bad)
        expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "expected_digest" } ])
      end
      expect(stored).to eq([ [ nil, nil, false, 50, 1 ] ])
    end

    it "a ordem dos itens no corpo não muda o digest" do
      list = [ item(days: 20, neighborhood_id: neighborhood.id, risk_class: "red"), item(days: 15, strategic_point: true),
               item(days: 40, risk_class: "red"), item(days: 60) ]
      put_items(list)
      first = json_body.fetch("digest")
      put_items([])
      put_items(list.reverse)
      expect(json_body.fetch("digest")).to eq(first)
      expect(current_digest).to eq(first)

      put_items(list.reverse.map { |row| row[:days] == 60 ? row.merge(days: 61) : row })
      expect(json_body.fetch("digest")).not_to eq(first)
    end
  end

  it "bairros em ordem de nome, não de id" do
    ids = Array.new(2) { SecureRandom.uuid }.sort
    zulu = Neighborhood.create!(id: ids.first, name: "Zumbi #{SecureRandom.hex(3)}", source: "manual")
    alpha = Neighborhood.create!(id: ids.last, name: "Água Verde #{SecureRandom.hex(3)}", source: "manual")
    VectorCadence.create!(neighborhood: zulu, days: 30)
    VectorCadence.create!(neighborhood: alpha, days: 40)
    VectorCadence.create!(days: 50)
    sign_in_as(coordinator)

    get "/vector_control/cadences"
    expect(json_body["items"].map { |row| row["neighborhood_id"] }).to eq([ nil, alpha.id, zulu.id ])
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
