require "rails_helper"

# Módulo 35a (contrato §5, §12; Q8): GET /vector_control/due, "Imóveis a
# visitar" do agente de endemias na microárea atribuída a ele, paginado, com
# a trilha territory_registry dos imóveis mostrados e sem morador.
RSpec.describe "Vigilância ambiental — imóveis a visitar", type: :request do
  let!(:city) { vector_city! }
  let(:agent) { endemic_agent! }
  let(:area) { MicroAreaFieldAssignment.active.find_by!(professional: agent.professional).micro_area }
  let(:neighborhood) { Neighborhood.create!(name: "Centro #{SecureRandom.hex(3)}", source: "manual") }

  def household! = registry_household_rows!(area, neighborhood_id: neighborhood.id)
  def trails = DomainEvent.where(name: "clinical_record.viewed")

  it "ACE na microárea atribuída → 200 paginado com next_before" do
    ids = Array.new(3) { household!.id }.sort
    sign_in_as(agent)

    get "/vector_control/due", params: { micro_area_id: area.id, limit: 2 }
    expect(response).to have_http_status(:ok)
    expect(json_body["items"].map { |item| item["household_id"] }).to eq(ids.first(2))
    expect(json_body["items"].first).to eq("household_id" => ids.first, "address_short" => "Rua das Flores, 120", "property_type" => "1",
                                           "block" => nil, "risk_class" => nil, "last_worked_on" => nil, "due_since" => nil,
                                           "reason" => "due", "liraa_draw_item_id" => nil, "transmission_block_id" => nil)
    cursor = json_body["next_before"]
    expect(cursor).to be_present

    get "/vector_control/due", params: { micro_area_id: area.id, limit: 2, before: cursor }
    expect(json_body).to match("items" => [ hash_including("household_id" => ids.last) ], "next_before" => nil)
    expect(trails.map(&:payload)).to contain_exactly(
      { "access" => "territory_registry", "micro_area_id" => area.id, "household_ids" => ids.first(2), "user_id" => agent.id },
      { "access" => "territory_registry", "micro_area_id" => area.id, "household_ids" => [ ids.last ], "user_id" => agent.id }
    )
  end

  it "microárea não atribuída → 403 out_of_scope; ACS → 403 cbo_not_allowed" do
    household!
    other_area = registry_micro_area!(code: "05", team: area.team)
    sign_in_as(agent)
    get "/vector_control/due", params: { micro_area_id: other_area.id }
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "out_of_scope" } ])

    sign_in_as(registry_acs_of(area))
    get "/vector_control/due", params: { micro_area_id: area.id }
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "cbo_not_allowed" } ])

    sign_in_as(endemic_coordinator!)
    get "/vector_control/due", params: { micro_area_id: area.id }
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "out_of_scope" } ])
    expect(trails).to be_empty
  end

  it "query: micro_area_id obrigatório, desconhecida → 404, chave a mais → 422, cursor adulterado → invalid_cursor" do
    sign_in_as(agent)
    get "/vector_control/due"
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "micro_area_id" } ])
    get "/vector_control/due", params: { micro_area_id: SecureRandom.uuid }
    expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
    get "/vector_control/due", params: { micro_area_id: area.id, name: "Maria" }
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request" } ])
    get "/vector_control/due", params: { micro_area_id: area.id, before: "x" }
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_cursor" } ])
    get "/vector_control/due", params: { micro_area_id: area.id, limit: 101 }
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_limit" } ])
  end

  it "gate desligado → 403 feature_disabled" do
    Platform::Features.set!(city: city, key: VectorControl::Gate::KEY, enabled: false, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
    sign_in_as(agent)
    get "/vector_control/due", params: { micro_area_id: area.id }
    expect([ response.status, json_body["error"] ]).to eq([ 403, "feature_disabled" ])
  end
end
