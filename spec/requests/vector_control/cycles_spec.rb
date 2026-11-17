require "rails_helper"

# Módulo 35a (contrato §5, §12; Q8, D-6): ciclos de trabalho da coordenação e
# o resumo por bairro (GET /cycles/:id, CycleSummary).
RSpec.describe "Vigilância ambiental — ciclos", type: :request do
  let!(:city) { vector_city! }
  let(:coordinator) { endemic_coordinator! }
  let(:year) { Time.zone.today.year }

  def create_cycle(**body) = json_post("/vector_control/cycles", body)

  it "cria, lista por ano e edita; o número sai do próximo do ano quando não vem" do
    sign_in_as(coordinator)
    create_cycle(year: year, number: 1, starts_on: "#{year}-01-05", ends_on: "#{year}-02-28")
    expect(response).to have_http_status(:created)
    first = json_body
    expect(first).to include("year" => year, "number" => 1, "starts_on" => "#{year}-01-05", "ends_on" => "#{year}-02-28")
    create_cycle(year: year, starts_on: "#{year}-03-01", ends_on: "#{year}-04-30")
    expect(json_body).to include("number" => 2)

    get "/vector_control/cycles", params: { year: year }
    expect(json_body["items"].map { |cycle| cycle["number"] }).to eq([ 1, 2 ])
    expect(json_body["items"].first.keys).to eq(%w[id year number starts_on ends_on])

    json_patch "/vector_control/cycles/#{first["id"]}", ends_on: "#{year}-02-20"
    expect(json_body).to include("ends_on" => "#{year}-02-20")
    expect(VectorCycle.find(first["id"]).version).to eq(2)
  end

  it "ciclo sobreposto → 422 cycle_overlap" do
    VectorCycle.create!(year: year, number: 1, starts_on: Date.new(year, 1, 1), ends_on: Date.new(year, 2, 28))
    sign_in_as(coordinator)
    create_cycle(year: year, number: 2, starts_on: "#{year}-02-28", ends_on: "#{year}-04-30")
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "cycle_overlap", "path" => "starts_on" } ])
    create_cycle(year: year, number: 1, starts_on: "#{year}-05-01", ends_on: "#{year}-06-30")
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "number" } ])
    create_cycle(year: year, number: 3, starts_on: "#{year}-08-01", ends_on: "#{year}-07-31")
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "cycle_invalid", "path" => "ends_on" } ])
    create_cycle(year: year, number: 13, starts_on: "#{year}-08-01", ends_on: "#{year}-08-31")
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "number" } ])
    create_cycle(year: year, number: 3, starts_on: "#{year}-02-30", ends_on: "#{year}-08-31")
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "starts_on" } ])
    expect(VectorCycle.count).to eq(1)
  end

  it "o ano do ciclo é o de starts_on → senão 422 cycle_invalid path year" do
    sign_in_as(coordinator)
    create_cycle(year: year + 1, number: 1, starts_on: "#{year}-12-01", ends_on: "#{year + 1}-01-31")
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "cycle_invalid", "path" => "year" } ])
    create_cycle(year: year, number: 12, starts_on: "#{year}-12-01", ends_on: "#{year + 1}-01-31")
    expect(response).to have_http_status(:created)

    json_patch "/vector_control/cycles/#{json_body["id"]}", starts_on: "#{year + 1}-01-02"
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "cycle_invalid", "path" => "year" } ])
    expect(VectorCycle.sole).to have_attributes(year: year, starts_on: Date.new(year, 12, 1), version: 1)
  end

  it "GET /cycles/:id traz o resumo por bairro com `pending_percent` e `registered_households`" do
    agent = endemic_agent!
    area = MicroAreaFieldAssignment.active.find_by!(professional: agent.professional).micro_area
    neighborhood = Neighborhood.create!(name: "Água Verde #{SecureRandom.hex(3)}", source: "manual")
    today = Time.zone.today
    cycle = VectorCycle.create!(year: today.year, number: 1, starts_on: today - 5, ends_on: today)
    day = home_visit_day!(agent: agent)
    { "worked" => 1, "closed" => 3 }.each_with_index do |(situation, outcome), index|
      household = registry_household_rows!(area, neighborhood_id: neighborhood.id)
      visit = home_visit!(day: day, micro_area: area, household: household, outcome: outcome,
                          occurred_at: today.in_time_zone.change(hour: 8) + index.minutes)
      VectorInspection.create!(home_visit: visit, household: household, activity: "li", work_type: "routine", situation: situation,
                               educational_action: false)
    end
    registry_household_rows!(area, neighborhood_id: neighborhood.id)
    sign_in_as(coordinator)

    get "/vector_control/cycles/#{cycle.id}"
    expect(response).to have_http_status(:ok)
    expect(json_body["cycle"]).to eq("id" => cycle.id, "year" => today.year, "number" => 1, "starts_on" => (today - 5).iso8601,
                                     "ends_on" => today.iso8601)
    row = json_body["neighborhoods"].find { |entry| entry["neighborhood"]["id"] == neighborhood.id }
    expect(row).to eq("neighborhood" => { "id" => neighborhood.id, "name" => neighborhood.name }, "to_visit" => 3, "visited" => 2,
                      "worked" => 1, "closed" => 1, "refused" => 0, "vacant" => 0, "recovered" => 0, "pending_percent" => 50.0,
                      "registered_households" => 3)

    get "/vector_control/cycles/#{SecureRandom.uuid}"
    expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
    sign_in_as(agent)
    get "/vector_control/cycles/#{cycle.id}"
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
  end
end
