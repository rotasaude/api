require "rails_helper"

RSpec.describe "Authoring::Protocols definition", type: :request do
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

  def create_pd
    ApplicationRecord.connection.execute(
      ApplicationRecord.sanitize_sql(["SET LOCAL app.municipality_id = ?", muni.id])
    )
    ProtocolDefinition.create!(
      name: "respiratoria", version: 1, status: "draft", municipality_id: muni.id,
      definition: {
        "name" => "respiratoria", "version" => 1, "start_step_id" => "s1",
        "steps" => [{ "id" => "s1", "prompt" => "?", "answer_type" => "boolean",
                      "branches" => { "true" => nil, "false" => nil } }]
      }
    )
  end

  it "returns the raw definition for an existing (name, version)" do
    sign_in(author)
    create_pd
    get "/authoring/protocols/definition", params: { name: "respiratoria", version: 1 }
    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body).dig("definition", "start_step_id")).to eq("s1")
  end

  it "404 for an unknown definition" do
    sign_in(author)
    get "/authoring/protocols/definition", params: { name: "nope", version: 9 }
    expect(response).to have_http_status(:not_found)
  end

  it "403 for a non-author session" do
    sign_in(viewer)
    get "/authoring/protocols/definition", params: { name: "respiratoria", version: 1 }
    expect(response).to have_http_status(:forbidden)
  end
end
