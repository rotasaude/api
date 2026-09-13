require "rails_helper"

RSpec.describe "Admin::Api::Reports", type: :request do
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

  def municipal_admin_for(muni, email:)
    user = User.create!(email_address: email, password: "secret123")
    Membership.create!(user: user, role: "municipal_admin", municipality_id: muni.id, granted_at: Time.current)
    user
  end

  it "an operator sees a city's reports as metadata, without token or payload" do
    muni = nil
    begin
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

  it "a municipal_admin sees only their own city's reports (per-city, not operator-only)" do
    mine = other = admin = nil
    begin
      mine  = Municipality.create!(name: "Mine", slug: "mine-#{SecureRandom.hex(3)}", uf: "SP", status: "active")
      other = Municipality.create!(name: "Other", slug: "other-#{SecureRandom.hex(3)}", uf: "RJ", status: "active")
      seed_report(mine,  tier: "alta")
      seed_report(other, tier: "baixa")
      admin = municipal_admin_for(mine, email: "adm-#{SecureRandom.hex(3)}@x.com")
    end
    sign_in_as(admin)

    get "/admin/api/reports", params: { period: "30d" }

    expect(response).to have_http_status(:ok)
    reports = JSON.parse(response.body).dig("data", "reports")
    expect(reports.size).to eq(1)           # só a cidade dele
    expect(reports.first["tier"]).to eq("alta")
  end

  it "requires authentication (401 when unauthenticated)" do
    get "/admin/api/reports", params: { period: "30d" }
    expect(response).to have_http_status(:unauthorized)
  end
end
