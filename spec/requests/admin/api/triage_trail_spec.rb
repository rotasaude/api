require "rails_helper"

# F-03.16 — inspeção do trail por triagem. O drawer do dashboard lê a
# explicação congelada no Outcome da triagem (F-03.7): só regras e
# referências, NUNCA a resposta crua do cidadão (ADR 0009).
RSpec.describe "GET /admin/api/triages/:id/trail", type: :request do
  before { Current.city = TEST_CITY_A }
  after { Current.reset; Rails.cache.clear }

  let(:viewer) do
    User.create!(email_address: "trail-#{SecureRandom.hex(4)}@x.com", password: "secret123").tap do |u|
      Membership.create!(user: u, role: "viewer", granted_at: 1.day.ago)
    end
  end

  def completed_triage(tosse:, febre: nil)
    protocol = create_default_protocol!
    convo = Conversation.create!(phone: "+55419#{rand(10_000_000..99_999_999)}", state: :consented)
    convo.consents.create!(
      version: Consents.current_version,
      policy_text_sha: Consents.policy_text_sha(Consents.current_version),
      given_at: 1.minute.ago, channel: "web", evidence: { text: "sim" }
    )
    triage = Triage.create!(conversation: convo, protocol_definition: protocol, protocol_name: protocol.name,
                            status: :in_progress, current_step: "tosse", answers: {})
    CompleteTriage.call(triage: triage, answer: tosse)
    CompleteTriage.call(triage: triage.reload, answer: febre) unless febre.nil?
    triage.reload
  end

  it "shows the engine explanation of a real triage, in order" do
    triage = completed_triage(tosse: "true", febre: "true")
    sign_in_as(viewer)

    get "/admin/api/triages/#{triage.id}/trail"

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)["data"]
    expect(body["mode"]).to eq("weighted")
    expect(body["steps"].map { |s| s.slice("ev", "rule", "ref", "out") }).to eq([
      { "ev" => "scored", "rule" => "weighted", "ref" => "step:tosse", "out" => "3" },
      { "ev" => "scored", "rule" => "weighted", "ref" => "step:febre", "out" => "5" },
      { "ev" => "tier_assigned", "rule" => "threshold", "ref" => "score:8", "out" => "alta" }
    ])
    expect(body["steps"]).to all(include("at" => triage.completed_at.iso8601))
  end

  it "never returns an answer, whatever the outcome holds" do
    triage = completed_triage(tosse: "true", febre: "true")
    sign_in_as(viewer)

    get "/admin/api/triages/#{triage.id}/trail"

    expect(response.body).not_to include("answer")
    expect(JSON.parse(response.body)["data"]["steps"]).to all(satisfy { |s| s.keys.sort == %w[at ev out ref rule] })
  end

  it "returns no steps for a triage completed before the explanation existed" do
    triage = completed_triage(tosse: "false")
    triage.update_columns(outcome: triage.outcome.except("explanation"))
    sign_in_as(viewer)

    get "/admin/api/triages/#{triage.id}/trail"

    expect(JSON.parse(response.body)["data"]["steps"]).to eq([])
  end
end
