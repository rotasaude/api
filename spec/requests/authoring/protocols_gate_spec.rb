require "rails_helper"

RSpec.describe "Authoring::Protocols gate", type: :request do
  let!(:muni) { create(:municipality) }

  let(:author) do
    u = User.create!(email_address: "author@example.org", password: "secret123")
    Membership.create!(user: u, municipality: muni, role: "protocol_author", granted_at: Time.current)
    u
  end

  let(:viewer) do
    u = User.create!(email_address: "viewer@example.org", password: "secret123")
    Membership.create!(user: u, municipality: muni, role: "viewer", granted_at: Time.current)
    u
  end

  def sign_in(user)
    session = user.sessions.create!(user_agent: "rspec", ip_address: "127.0.0.1")
    allow_any_instance_of(Authoring::ProtocolsController).to receive(:resume_session) { Current.session = session }
    allow_any_instance_of(Authoring::ProtocolsController).to receive(:current_municipality).and_return(muni)
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
    sign_in(viewer)
    post "/authoring/protocols/gate", params: { definition: valid_def }, as: :json
    expect(response).to have_http_status(:forbidden)
  end

  it "200 valid:true for a gate-valid definition" do
    sign_in(author)
    post "/authoring/protocols/gate", params: { definition: valid_def }, as: :json
    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)).to eq("valid" => true)
  end

  it "422 with errors for a gate-invalid definition" do
    sign_in(author)
    bad = valid_def
    bad["scoring"]["priority_map"]["baixa"] = 99
    post "/authoring/protocols/gate", params: { definition: bad }, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    body = JSON.parse(response.body)
    expect(body["valid"]).to be false
    expect(body["errors"]).to be_present
  end
end
