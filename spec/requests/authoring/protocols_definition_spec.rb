require "rails_helper"

# City is the request's host city (TEST_CITY_A, the harness default — see
# spec/support/city_request_auth.rb): no separate Municipality/City fixture
# needed. `sign_in_as` (city_request_auth.rb) creates a real Session and
# plants the signed cookie, so Authentication/Current.user/ProtocolPolicy run
# through the real flow — no controller stubbing.
RSpec.describe "Authoring::Protocols definition", type: :request do
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

  def create_pd
    ProtocolDefinition.create!(
      name: "respiratoria", version: 1, status: "draft",
      definition: {
        "name" => "respiratoria", "version" => 1, "start_step_id" => "s1",
        "steps" => [{ "id" => "s1", "prompt" => "?", "answer_type" => "boolean",
                      "branches" => { "true" => nil, "false" => nil } }]
      }
    )
  end

  it "returns the raw definition for an existing (name, version)" do
    sign_in_as(author)
    create_pd
    get "/authoring/protocols/definition", params: { name: "respiratoria", version: 1 }
    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body).dig("definition", "start_step_id")).to eq("s1")
  end

  it "404 for an unknown definition" do
    sign_in_as(author)
    get "/authoring/protocols/definition", params: { name: "nope", version: 9 }
    expect(response).to have_http_status(:not_found)
  end

  it "403 for a non-author session" do
    sign_in_as(viewer)
    get "/authoring/protocols/definition", params: { name: "respiratoria", version: 1 }
    expect(response).to have_http_status(:forbidden)
  end
end
