require "rails_helper"

RSpec.describe "Authoring::Protocols draft", type: :request do
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
    ApplicationRecord.connected_to(role: :admin) do
      ProtocolDefinition.find_by(name: "respiratoria", version: version, municipality_id: muni.id)
    end
  end

  it "creates a draft for a new (name, version)" do
    sign_in(author)
    post "/authoring/protocols/draft", params: { definition: valid_def }, as: :json
    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body["status"]).to eq("draft")
    expect(find_pd(version: 1).status).to eq("draft")
  end

  it "updates the definition of an existing draft" do
    sign_in(author)
    post "/authoring/protocols/draft", params: { definition: valid_def }, as: :json
    changed = valid_def
    changed["steps"][0]["prompt"] = "Está tossindo?"
    post "/authoring/protocols/draft", params: { definition: changed }, as: :json
    expect(response).to have_http_status(:ok)
    expect(find_pd(version: 1).definition["steps"][0]["prompt"]).to eq("Está tossindo?")
  end

  it "422 version_not_editable when the version is already published" do
    ApplicationRecord.connection.execute(
      ApplicationRecord.sanitize_sql(["SET LOCAL app.municipality_id = ?", muni.id])
    )
    ProtocolDefinition.create!(name: "respiratoria", version: 1, status: "published",
                               municipality_id: muni.id, definition: valid_def)
    sign_in(author)
    post "/authoring/protocols/draft", params: { definition: valid_def }, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(JSON.parse(response.body)["error"]).to eq("version_not_editable")
  end

  it "403 for a non-author session" do
    sign_in(viewer)
    post "/authoring/protocols/draft", params: { definition: valid_def }, as: :json
    expect(response).to have_http_status(:forbidden)
  end
end
