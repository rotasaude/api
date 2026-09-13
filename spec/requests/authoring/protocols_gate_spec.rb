require "rails_helper"

# City is the request's host city (TEST_CITY_A, the harness default — see
# spec/support/city_request_auth.rb). `sign_in_as` (city_request_auth.rb)
# creates a real Session and plants the signed cookie — no controller
# stubbing needed.
RSpec.describe "Authoring::Protocols gate", type: :request do
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

  def valid_def
    {
      "name" => "respiratoria", "version" => 1, "start_step_id" => "tosse",
      "steps" => [
        { "id" => "tosse", "prompt" => "Tosse?", "answer_type" => "boolean",
          "branches" => { "true" => nil, "false" => nil }, "weights" => { "true" => 5, "false" => 0 } }
      ],
      "scoring" => { "type" => "weighted", "thresholds" => { "baixa" => 0 }, "priority_map" => { "baixa" => 9 } }
    }
  end

  it "401 when unauthenticated" do
    post "/authoring/protocols/gate", params: { definition: valid_def }, as: :json
    expect(response).to have_http_status(:unauthorized)
  end

  it "403 when the session is not an author" do
    sign_in_as(viewer)
    post "/authoring/protocols/gate", params: { definition: valid_def }, as: :json
    expect(response).to have_http_status(:forbidden)
  end

  it "200 valid:true for a gate-valid definition" do
    sign_in_as(author)
    post "/authoring/protocols/gate", params: { definition: valid_def }, as: :json
    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)).to eq("valid" => true)
  end

  it "422 with errors for a gate-invalid definition" do
    sign_in_as(author)
    bad = valid_def
    bad["scoring"]["priority_map"]["baixa"] = 99
    post "/authoring/protocols/gate", params: { definition: bad }, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    body = JSON.parse(response.body)
    expect(body["valid"]).to be false
    expect(body["errors"]).to be_present
  end
end
