require "rails_helper"

# A1 do final-fix-brief (2026-09-22-dashboard-signatures-03-protocolos): a
# leitura colapsava `active` em `published`, escondendo do painel a versão
# que está de fato em uso na cidade. `status_label` agora devolve `active`
# sem tocar em draft/published/retired.
RSpec.describe "Admin protocols — status label distingue active de published", type: :request do
  def json = JSON.parse(response.body)

  let!(:admin_user) do
    User.create!(email_address: "muadmin-#{SecureRandom.hex(3)}@example.org", password: "secret123").tap do |u|
      Membership.create!(user: u, role: "municipal_admin", granted_at: Time.current)
    end
  end

  before { sign_in_as(admin_user) }

  it "uma versão active chega como status: active e revertible: true quando há ativação assinada anterior" do
    legacy = ProtocolDefinition.create!(name: "coqueluche2", version: 1, status: "active",
                                        definition: protocol_definition_hash(name: "coqueluche2"))
    legacy.activations.create!(kind: "baseline", actor_kind: "system", actor_id: nil)

    v2 = ProtocolDefinition.create!(name: "coqueluche2", version: 2, status: "published",
                                    definition: protocol_definition_hash(name: "coqueluche2", version: 2))
    ana = make_reviewer!
    bia = make_reviewer!
    sign!(v2, purpose: "activation", by: ana)
    sign!(v2, purpose: "activation", by: bia)
    publisher = User.create!(email_address: "pub-#{SecureRandom.hex(3)}@example.org", password: "secret123").tap do |u|
      Membership.create!(user: u, role: "protocol_publisher", granted_at: Time.current)
    end
    expect(Protocols::Activate.call(version: 2, name: "coqueluche2", by: publisher).ok?).to be(true)

    get "/admin/api/protocols/coqueluche2"
    expect(response).to have_http_status(:ok)

    v2_after = json["data"]["versions"].find { |v| v["version"] == "2" }
    expect(v2_after["status"]).to eq("active")
    expect(v2_after["revertible"]).to be(true)
  end

  it "uma versão published continua published" do
    ProtocolDefinition.create!(name: "rubeola2", version: 1, status: "published",
                              definition: protocol_definition_hash(name: "rubeola2"))

    get "/admin/api/protocols/rubeola2"
    version = json["data"]["versions"].find { |v| v["version"] == "1" }
    expect(version["status"]).to eq("published")
  end

  it "index (GET /admin/api/protocols) também devolve active sem colapsar" do
    pd = ProtocolDefinition.create!(name: "tetano2", version: 1, status: "active",
                                    definition: protocol_definition_hash(name: "tetano2"))
    pd.activations.create!(kind: "baseline", actor_kind: "system", actor_id: nil)

    get "/admin/api/protocols"
    row = json["data"]["list"].find { |r| r["name"] == "tetano2" }
    expect(row["status"]).to eq("active")
  end
end
