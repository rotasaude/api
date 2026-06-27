require "rails_helper"
require Rails.root.join("spec/support/admin_rls")

RSpec.describe "Reports", type: :request do
  # ReportsController reads via connected_to(role: :admin); needs the real admin
  # connection — see spec/support/admin_rls.
  self.use_transactional_tests = false

  before { clean_admin_tables }
  after  { clean_admin_tables }

  def create_snapshot(payload:)
    as_admin do
      muni = Municipality.create!(name: "Rec City", slug: "rec-city", ibge_code: "3500001")
      pd = ProtocolDefinition.create!(
        name: "triagem-rec", version: 1, status: "active", municipality_id: muni.id,
        definition: {
          "name" => "triagem-rec", "version" => 1, "start_step_id" => "s1",
          "steps" => [{ "id" => "s1", "prompt" => "?", "answer_type" => "boolean",
                        "branches" => { "true" => nil, "false" => nil } }]
        }
      )
      convo = Conversation.create!(municipality_id: muni.id, phone: "+5511999990001", state: "greeting")
      triage = Triage.create!(
        conversation: convo, protocol_definition: pd, protocol_name: "triagem-rec",
        municipality_id: muni.id, status: "completed", tier: "alta", priority: 1,
        completed_at: Time.current, outcome: { "trail" => [] }
      )
      token = ReportSnapshot.mint_token
      ReportSnapshot.create!(
        triage: triage, protocol_definition: pd, municipality_id: muni.id,
        outcome: { "tier" => "alta" }, payload: payload,
        token: token, signature: ReportSnapshot.sign(token), expires_at: 30.days.from_now
      )
    end
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
end
