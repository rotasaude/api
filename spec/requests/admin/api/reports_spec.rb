require "rails_helper"
require Rails.root.join("spec/support/admin_rls")
require Rails.root.join("spec/support/admin_auth")

RSpec.describe "Admin::Api::Reports", type: :request do
  self.use_transactional_tests = false
  before { clean_admin_tables }
  after  { clean_admin_tables }

  def seed_report(muni, tier: "alta", token: "tok-#{SecureRandom.hex(4)}")
    pd = ProtocolDefinition.create!(municipality_id: muni.id, name: "resp", version: 3, status: "active",
                                    definition: { "name" => "resp", "version" => 3, "start_step_id" => "s1",
                                                  "steps" => [{ "id" => "s1", "prompt" => "?", "answer_type" => "boolean" }] })
    convo = Conversation.create!(municipality_id: muni.id, phone: "+5511#{rand(1000..9999)}", state: "completed")
    triage = Triage.create!(conversation: convo, protocol_definition: pd, protocol_name: "resp",
                            municipality_id: muni.id, status: "completed", tier: tier, answers: {})
    ReportSnapshot.create!(triage: triage, protocol_definition: pd, municipality_id: muni.id,
                           token: token, signature: "sig-#{token}",
                           payload: { "secret_clinical" => "NEVER-EXPOSE" }, outcome: { "tier" => tier, "priority" => 2 },
                           expires_at: 10.days.from_now)
  end

  it "lists the city's reports as metadata, without token or payload" do
    muni = nil
    as_admin do
      muni = Municipality.create!(name: "RepCity", slug: "rep-city", uf: "SP", status: "active")
      seed_report(muni, tier: "alta", token: "TOK-SECRET-123")
    end
    sign_in_as(operator!)

    get "/admin/api/reports", params: { period: "30d", municipality_id: muni.id }

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    reports = body.dig("data", "reports")
    expect(reports.size).to eq(1)
    row = reports.first
    expect(row["tier"]).to eq("alta")
    expect(row["protocol"]).to eq("resp · 3")
    expect(row["createdAt"]).to be_present
    expect(row).to have_key("live")
    expect(body["as_of"]).to be_present
    # LGPD: no token / payload / signature anywhere in the response
    expect(response.body).not_to include("TOK-SECRET-123")
    expect(response.body).not_to include("NEVER-EXPOSE")
  end

  it "denies a non-authorized user" do
    user = User.create!(email_address: "muni-#{SecureRandom.hex(3)}@x.com", password: "secret123")
    sign_in_as(user)
    get "/admin/api/reports", params: { period: "30d" }
    expect(response).to have_http_status(:forbidden)
  end
end
