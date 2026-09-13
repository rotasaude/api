require "rails_helper"

# City is the request's host city (TEST_CITY_A, the harness default — see
# spec/support/city_request_auth.rb). `sign_in_as` (city_request_auth.rb)
# creates a real Session and plants the signed cookie — no controller
# stubbing needed.
RSpec.describe "Authoring::Protocols draft", type: :request do
  let(:author) do
    u = User.create!(email_address: "author@example.org", password: "secret123")
    Membership.create!(user: u, role: "protocol_author", granted_at: Time.current)
    u
  end

  let(:viewer) do
    u = User.create!(email_address: "viewer@example.org", password: "secret123")
    Membership.create!(user: u, role: "viewer", granted_at: Time.current)
    u
  end

  def valid_def(version: 1)
    {
      "name" => "respiratoria", "version" => version, "start_step_id" => "tosse",
      "steps" => [
        { "id" => "tosse", "prompt" => "Tosse?", "answer_type" => "boolean",
          "branches" => { "true" => nil, "false" => nil }, "weights" => { "true" => 5, "false" => 0 } }
      ],
      "scoring" => { "type" => "weighted", "thresholds" => { "baixa" => 0 }, "priority_map" => { "baixa" => 9 } }
    }
  end

  def find_pd(version:)
    ProtocolDefinition.find_by(name: "respiratoria", version: version)
  end

  it "creates a draft for a new (name, version)" do
    sign_in_as(author)
    post "/authoring/protocols/draft", params: { definition: valid_def }, as: :json
    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body["status"]).to eq("draft")
    expect(find_pd(version: 1).status).to eq("draft")
  end

  it "updates the definition of an existing draft" do
    sign_in_as(author)
    post "/authoring/protocols/draft", params: { definition: valid_def }, as: :json
    changed = valid_def
    changed["steps"][0]["prompt"] = "Está tossindo?"
    post "/authoring/protocols/draft", params: { definition: changed }, as: :json
    expect(response).to have_http_status(:ok)
    expect(find_pd(version: 1).definition["steps"][0]["prompt"]).to eq("Está tossindo?")
  end

  it "422 version_not_editable when the version is already published" do
    ProtocolDefinition.create!(name: "respiratoria", version: 1, status: "published", definition: valid_def)
    sign_in_as(author)
    post "/authoring/protocols/draft", params: { definition: valid_def }, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(JSON.parse(response.body)["error"]).to eq("version_not_editable")
  end

  it "403 for a non-author session" do
    sign_in_as(viewer)
    post "/authoring/protocols/draft", params: { definition: valid_def }, as: :json
    expect(response).to have_http_status(:forbidden)
  end
end
