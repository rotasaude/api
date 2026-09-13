require "rails_helper"

# City is the request's host city (TEST_CITY_A, the harness default — see
# spec/support/city_request_auth.rb). `sign_in_as` (city_request_auth.rb)
# creates a real Session and plants the signed cookie — no controller
# stubbing needed.
RSpec.describe "Authoring::Protocols preview", type: :request do
  let(:author) do
    u = User.create!(email_address: "author@example.org", password: "secret123")
    Membership.create!(user: u, role: "protocol_author", granted_at: Time.current)
    u
  end

  def valid_def
    {
      "name" => "respiratoria", "version" => 1, "start_step_id" => "tosse",
      "steps" => [
        { "id" => "tosse", "prompt" => "Tosse?", "answer_type" => "boolean",
          "branches" => { "true" => nil, "false" => nil }, "weights" => { "true" => 5, "false" => 0 } }
      ],
      "scoring" => { "type" => "weighted", "thresholds" => { "baixa" => 0, "alta" => 5 },
                     "priority_map" => { "baixa" => 9, "alta" => 1 } }
    }
  end

  before { sign_in_as(author) }

  it "returns the terminal outcome for a complete set of answers" do
    post "/authoring/protocols/preview",
         params: { definition: valid_def, answers: { "tosse" => "true" } }, as: :json
    expect(response).to have_http_status(:ok)
    outcome = JSON.parse(response.body)["outcome"]
    expect(outcome["status"]).to eq("terminal")
    expect(outcome["tier"]).to eq("alta")
  end

  it "returns the pending step when answers are incomplete" do
    post "/authoring/protocols/preview",
         params: { definition: valid_def, answers: {} }, as: :json
    expect(response).to have_http_status(:ok)
    outcome = JSON.parse(response.body)["outcome"]
    expect(outcome["status"]).to eq("pending")
    expect(outcome["awaiting"]).to eq("tosse")
  end

  it "422 with errors when the definition fails the gate" do
    bad = valid_def
    bad["steps"][0]["answer_type"] = "color"
    post "/authoring/protocols/preview",
         params: { definition: bad, answers: {} }, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(JSON.parse(response.body)["errors"]).to be_present
  end
end
