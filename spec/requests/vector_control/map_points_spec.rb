require "rails_helper"

# Módulo 35a, Task 13 (ADR 0054; contrato §17; Q8, Q13(7)): GET
# /vector_control/map_points?layer=risk|ovitraps|transmission → `{ map,
# points: [{ id, latitude, longitude, category, label }] }` com o ponto do
# domicílio do 24c (sem ponto, fora). A camada do bloqueio nunca traz o caso;
# a coordenada nunca sai junto de caso nem de pessoa. Ler os pontos grava a
# trilha territory_map por microárea.
RSpec.describe "Vigilância ambiental — pontos do mapa", type: :request do
  let!(:city) { block_city! }
  let(:coordinator) { endemic_coordinator! }
  let(:agent) { endemic_agent! }
  let(:area) { MicroAreaFieldAssignment.active.find_by!(professional: agent.professional).micro_area }
  let(:neighborhood) { Neighborhood.create!(name: "Centro #{SecureRandom.hex(3)}", source: "manual") }
  let(:center) { city_block!(neighborhood: neighborhood, number: "10") }
  let(:neighbor) { city_block!(neighborhood: neighborhood, number: "11") }
  let(:far) { city_block!(neighborhood: neighborhood, number: "30") }
  let(:base) { "/vector_control/map_points" }

  before { allow(Ledi::DeliverJob).to receive(:perform_later) }
  after { Current.reset }

  def spot(n) = { "latitude" => -25.4284 - (n / 1000.0), "longitude" => -49.2733 + (n / 1000.0), "source" => "map" }

  # Domicílio ativo na microárea do agente, no bairro do quarteirão, com o
  # perfil nele; `location: nil` = sem ponto do 24c.
  def home!(block, location:, risk: nil)
    household = registry_household_rows!(area, neighborhood_id: block.neighborhood_id, **(location ? { location: location } : {}))
    vector_profile!(household, block: block, risk: risk)
    household
  end

  def point(id, location, category, label)
    { "id" => id, "latitude" => location["latitude"], "longitude" => location["longitude"], "category" => category, "label" => label }
  end

  def map_trails = DomainEvent.where(name: "clinical_record.viewed").where("payload->>'access' = 'territory_map'").map(&:payload)

  it "camada risk: risk_class ou none, rótulo do quarteirão; domicílio sem location fora; trilha territory_map" do
    red = home!(center, location: spot(1), risk: "red")
    plain = home!(neighbor, location: spot(2))
    home!(center, location: nil, risk: "red")
    home!(city_block!(neighborhood: Neighborhood.create!(name: "Batel #{SecureRandom.hex(3)}", source: "manual"), number: "1"),
          location: spot(3))
    published_field_map!(city)

    sign_in_as(coordinator)
    get base, params: { layer: "risk", neighborhood_id: neighborhood.id }
    expect(response).to have_http_status(:ok)
    expect(json_body["map"]).to eq(JSON.parse(FieldMap.published_for(city.id).manifest.to_json))
    expected = [ point(red.id, spot(1), "red", "10"), point(plain.id, spot(2), "none", "11") ].sort_by { |item| item["id"] }
    expect(json_body["points"]).to eq(expected)
    expect(map_trails).to eq([ { "access" => "territory_map", "micro_area_id" => area.id,
                                 "household_ids" => expected.map { |item| item["id"] }, "user_id" => coordinator.id } ])
    expect(response.body).not_to include("das Flores")
  end

  it "camada transmission só com os domicílios da área, sem o caso (sem patient_id nem notification_id em lugar nenhum)" do
    block_neighbors!(center, neighbor)
    patient = block_case_patient!(block: center)
    block_case = proposed_case!(patient: patient)
    block = block_case.transmission_block
    expect(VectorControl::Blocks::Confirm.call(block: block, center_block_id: center.id, block_ids: [ center.id, neighbor.id ],
                                               seen_case_ids: [ block_case.id ], by: coordinator)).to be_ok
    inside = home!(center, location: spot(1))
    next_door = home!(neighbor, location: spot(2), risk: "yellow")
    home!(far, location: spot(3))
    home!(center, location: nil)

    sign_in_as(coordinator)
    get base, params: { layer: "transmission", transmission_block_id: block.id }
    expect(response).to have_http_status(:ok)
    expected = [ point(inside.id, spot(1), "area", "10"), point(next_door.id, spot(2), "area", "11") ].sort_by { |item| item["id"] }
    expect(json_body).to eq("map" => nil, "points" => expected)

    trails = map_trails
    case_household = IndividualRegistration.find_by!(patient: patient).household_id
    [ response.body, trails.to_json ].each do |text|
      [ patient.id, block_case.disease_notification_id, block_case.id, case_household, patient.full_name ].each do |secret|
        expect(text).not_to include(secret)
      end
      expect(text).not_to include("patient_id", "notification_id")
    end
    expect(trails.map { |payload| payload["household_ids"] }).to eq([ expected.map { |item| item["id"] } ])

    get base, params: { layer: "transmission", transmission_block_id: SecureRandom.uuid }
    expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
  end

  it "ovitraps com category alert para 100 ovos; o vector_lab lê só esta camada" do
    week = Surveillance::EpiWeek.parse("2026-41")
    lab = vector_lab!
    trap = lambda do |number, location|
      Ovitrap.create!(number: number, household: home!(center, location: location), city_block: center, consent_at: Time.current,
                      installed_on: week.starts_on, installed_by_user: agent, origin: "dashboard")
    end
    read = lambda do |ovitrap, eggs, condition: "ok"|
      counted = eggs.nil? ? {} : { egg_count: eggs, counted_at: Time.current, counted_by_user: lab }
      OvitrapReading.create!(ovitrap: ovitrap, installed_on: week.starts_on + 1, epi_week: VectorControl::OvitrapIndex.week_of(week.starts_on + 1),
                             collected_on: week.starts_on + 6, condition: condition, **counted)
    end
    alert = trap.call("OV-1", spot(1))
    read.call(alert, 100)
    positive = trap.call("OV-2", spot(2))
    read.call(positive, 99)
    negative = trap.call("OV-3", spot(3))
    read.call(negative, 0)
    lost = trap.call("OV-4", spot(4))
    read.call(lost, nil, condition: "lost")
    trap.call("OV-5", nil)

    sign_in_as(lab)
    get base, params: { layer: "ovitraps", neighborhood_id: neighborhood.id, epi_week: "2026-41" }
    expect(response).to have_http_status(:ok)
    expect(json_body["points"]).to eq([ point(alert.id, spot(1), "alert", "OV-1 · 100"),
                                        point(positive.id, spot(2), "positive", "OV-2 · 99"),
                                        point(negative.id, spot(3), "negative", "OV-3 · 0"),
                                        point(lost.id, spot(4), "not_counted", "OV-4 · —") ].sort_by { |item| item["id"] })
    expect(map_trails.sole["household_ids"]).to match_array([ alert, positive, negative, lost ].map(&:household_id))

    get base, params: { layer: "risk", neighborhood_id: neighborhood.id }
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
    sign_in_as(agent)
    get base, params: { layer: "ovitraps", neighborhood_id: neighborhood.id, epi_week: "2026-41" }
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
  end

  it "layer desconhecida → 422 invalid_request path layer" do
    sign_in_as(coordinator)
    get base, params: { layer: "heat", neighborhood_id: neighborhood.id }
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "layer" } ])
    get base
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "layer" } ])
    get base, params: { layer: "ovitraps", neighborhood_id: neighborhood.id, epi_week: "2026-4" }
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "epi_week" } ])
    get base, params: { layer: "risk", neighborhood_id: "1" }
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "neighborhood_id" } ])
    get base, params: { layer: "risk", neighborhood_id: neighborhood.id, epi_week: "2026-41" }
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request" } ])
    get base, params: { layer: "risk", neighborhood_id: SecureRandom.uuid }
    expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
  end
end
