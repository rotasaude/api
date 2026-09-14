require "rails_helper"

# City is the request's host city. The default host (city_request_auth.rb) is
# TEST_CITY_A — the harness's own default connection — so `create_snapshot`
# writing plain rows (no `municipality_id:`, that column never existed on
# these tables in db/city_schema.rb) is visible to a request against the
# default host with no extra setup.
RSpec.describe "Reports", type: :request do
  def create_snapshot(payload:)
    pd = ProtocolDefinition.create!(
      name: "triagem-rec", version: 1, status: "active",
      definition: {
        "name" => "triagem-rec", "version" => 1, "start_step_id" => "s1",
        "steps" => [{ "id" => "s1", "prompt" => "?", "answer_type" => "boolean",
                      "branches" => { "true" => nil, "false" => nil } }]
      }
    )
    convo = Conversation.create!(phone: "+5511999990001", state: "greeting")
    triage = Triage.create!(
      conversation: convo, protocol_definition: pd, protocol_name: "triagem-rec",
      status: "completed", tier: "alta", priority: 1,
      completed_at: Time.current, outcome: { "trail" => [] }
    )
    token = ReportSnapshot.mint_token
    ReportSnapshot.create!(
      triage: triage, protocol_definition: pd,
      outcome: { "tier" => "alta" }, payload: payload,
      token: token, signature: ReportSnapshot.sign(token), expires_at: 30.days.from_now
    )
  end

  it "includes recommendation in the JSON" do
    snap = create_snapshot(payload: {
      "tier" => "alta", "priority" => 1,
      "recommendation" => { "title" => "Procure atendimento hoje", "body" => "Va a UPA." },
      "summary" => [], "completed_at" => "2026-06-27T12:00:00Z"
    })
    get "/r/#{snap.token}"
    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body["recommendation"]).to eq("title" => "Procure atendimento hoje", "body" => "Va a UPA.")
  end

  it "returns recommendation nil when absent from the payload" do
    snap = create_snapshot(payload: {
      "tier" => "alta", "priority" => 1, "summary" => [], "completed_at" => nil
    })
    get "/r/#{snap.token}"
    body = JSON.parse(response.body)
    expect(body).to have_key("recommendation")
    expect(body["recommendation"]).to be_nil
  end

  it "a token minted in one city does not resolve on another city's host" do
    other_city = create(:city, slug: TEST_CITY_B.slug, status: "active",
                               database_url: city_database_url("rota_saude_test_city_b"))
    snap = CityConnection.with(other_city) do
      create_snapshot(payload: { "tier" => "alta", "priority" => 1, "summary" => [], "completed_at" => nil })
    end

    # Same token, on TEST_CITY_A's host (the default): the row lives in a
    # completely different database/connection, so it does not exist there.
    get "/r/#{snap.token}", headers: { "HOST" => test_city_host }
    expect(response).to have_http_status(:not_found)

    # The very same token DOES resolve on the city it was actually minted in.
    get "/r/#{snap.token}", headers: { "HOST" => "#{other_city.slug}.rotasaude.app" }
    expect(response).to have_http_status(:ok)
  end
end
