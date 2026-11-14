require "rails_helper"

# Módulo 24c (ADR 0053; contrato §3.1, Q14, Q38): GET /territory/map/households
# dá ao mapa do dashboard os pontos dos domicílios ATIVOS de uma microárea e o
# manifesto do mapa publicado. Leitura nominal: uma trilha por consulta (access
# territory_map), só com ids. Só o mínimo no ponto: rua, número e famílias.
RSpec.describe "Mapa de campo no dashboard — GET /territory/map/households", type: :request do
  let!(:city) { home_visit_city! }
  let(:unit) { care_unit! }
  let(:team) { registry_team!(unit) }
  let(:acs) { registry_acs!(unit, team: team) }
  let!(:area) { registry_micro_area!(code: "01", team: team, acs: acs) }
  let(:point) { { "latitude" => -25.42847123, "longitude" => -49.27325411, "accuracy_m" => 8.5, "source" => "gps" } }

  def with_point!(micro_area = area, location: point)
    household = registry_household!(micro_area: micro_area)
    registry_new_household_version!(household, location: location)
    household.reload
  end

  def points(micro_area_id = area.id, **extra) = get("/territory/map/households", params: { micro_area_id: micro_area_id }.merge(extra))
  def trail = DomainEvent.where(name: "clinical_record.viewed").select { |event| event.payload["access"] == "territory_map" }

  before { |example| sign_in_as(acs) unless example.metadata[:anonymous] }

  it "só domicílios ativos com ponto, com rua, número, famílias e versão; o resto do cadastro fica fora" do
    marked = with_point!
    registry_family!(marked)
    marked.reload
    with_point!(location: nil) # sem ponto
    inactive = with_point!
    inactive.update_columns(status: "inactive")

    points
    expect(response).to have_http_status(:ok)
    expect(json_body.keys).to match_array(%w[map items])
    expect(json_body.fetch("items")).to eq([ { "id" => marked.id, "location" => point,
                                               "address" => { "street" => registry_address["street"], "number" => registry_address["number"] },
                                               "families_count" => 1, "version" => marked.version } ])
    text = response.body
    [ registry_address["zip"], registry_address["complement"], "contact_phone", "responsible", "living_conditions" ].compact.each do |hidden|
      expect(text).not_to include(hidden.to_s)
    end
  end

  it "família em mudança não conta" do
    household = with_point!
    family = registry_family!(household)
    family.update_columns(moved_out: true)
    points
    expect(json_body.dig("items", 0, "families_count")).to eq(0)
  end

  it "map é null sem mapa publicado e o manifesto da sessão com mapa (Q14)" do
    with_point!
    points
    expect(json_body).to include("map" => nil)
    published_field_map!(city)
    points
    expect(json_body.fetch("map")).to eq("version" => "2026-11-01", "size_bytes" => field_map_bytes.bytesize, "sha256" => field_map_sha)
  end

  it "uma trilha por consulta, com exatamente os domicílios mostrados; lista vazia não grava" do
    expect { points }.not_to change { trail.size }
    expect(json_body.fetch("items")).to eq([])

    first = with_point!
    second = with_point!
    expect { points }.to change { trail.size }.by(1)
    payload = trail.max_by(&:created_at).payload
    expect(payload.keys).to match_array(%w[access micro_area_id household_ids user_id])
    expect(payload).to include("access" => "territory_map", "micro_area_id" => area.id, "user_id" => acs.id)
    expect(payload["household_ids"]).to match_array([ first.id, second.id ])
    expect(json_body.fetch("items").map { _1["id"] }).to eq([ first.id, second.id ].sort)
  end

  it "o log não tem a coordenada" do
    with_point!
    log = capture_log { points }
    expect(log).not_to include("25.428")
    expect(log).not_to include("49.273")
  end

  it "o CBO de campo atribuído à microárea também vê; sem atribuição, 403" do
    with_point!
    tacs = field_agent!(cbo: "322255", team: team)
    sign_in_as(tacs)
    points
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "out_of_scope" } ])
    assignment!(area, tacs.professional)
    points
    expect(response).to have_http_status(:ok)
    expect(json_body.fetch("items").size).to eq(1)
  end

  it "microárea alheia → 403; inexistente → 404; sem micro_area_id ou com outra chave → 422, sem trilha" do
    other = registry_micro_area!(code: "02", team: team, acs: registry_acs!(unit, team: team))
    with_point!(other)
    expect do
      points(other.id)
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "out_of_scope" } ])
      points(SecureRandom.uuid)
      expect(response).to have_http_status(:not_found)
      get "/territory/map/households"
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request" } ])
      points("abc")
      expect(response).to have_http_status(:unprocessable_entity)
      points(area.id, cpf: "52998224725")
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request" } ])
    end.not_to change { trail.size }
  end

  it "sem sessão → 401", :anonymous do
    get "/territory/map/households", params: { micro_area_id: area.id }
    expect(response).to have_http_status(:unauthorized)
  end
end
