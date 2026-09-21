require "rails_helper"

# Task 5 do plano "assinaturas — API da cidade": o painel da cidade lê o
# estado das assinaturas de cada versão (spec de assinaturas §5/§6) direto das
# três tabelas — nunca de domain_events. Sessão de municipal_admin, como os
# outros specs de spec/requests/admin/ (spec/requests/admin/api/*.rb).
RSpec.describe "Admin protocols — signature state", type: :request do
  def json = JSON.parse(response.body)

  let!(:admin_user) do
    User.create!(email_address: "muadmin-#{SecureRandom.hex(3)}@example.org", password: "secret123").tap do |u|
      Membership.create!(user: u, role: "municipal_admin", granted_at: Time.current)
    end
  end

  before { sign_in_as(admin_user) }

  it "signers lista só as assinaturas válidas agora; missing conta o que falta; eligibleReviewers exclui quem editou" do
    pd = ProtocolDefinition.create!(name: "dengue", version: 1, status: "in_review",
                                    definition: protocol_definition_hash(name: "dengue"))
    valid_signer = make_reviewer!
    stale_signer = make_reviewer!
    editing_reviewer = make_reviewer!

    sign!(pd, purpose: "publication", by: valid_signer)
    # Assinatura de conteúdo antigo: digest que não é mais o do protocolo —
    # não conta (Protocols::Signatures filtra por content_digest atual).
    ProtocolSignature.create!(protocol_definition: pd, purpose: "publication", signer: stale_signer,
                              content_digest: "old-digest-does-not-match")
    # Revisor que editou a versão nunca é elegível a assinar (Signatures
    # exclui contribuintes) — não deve entrar em eligibleReviewers.
    ProtocolContribution.create!(protocol_definition: pd, actor_id: editing_reviewer.id, actor_kind: "user",
                                 content_digest: pd.content_digest)

    get "/admin/api/protocols/dengue"
    expect(response).to have_http_status(:ok)

    version = json["data"]["versions"].find { |v| v["version"] == "1" }
    publication = version["signatures"]["publication"]

    expect(publication["signers"]).to eq([ { "id" => valid_signer.id, "email" => valid_signer.email_address } ])
    expect(publication["missing"]).to eq(1)
    expect(version["eligibleReviewers"]).to eq(2)
  end

  it "editors lista o autor (com e-mail) e um mantenedor (kind: maintainer, email: null)" do
    pd = ProtocolDefinition.create!(name: "hanseniase", version: 1, status: "in_review",
                                    definition: protocol_definition_hash(name: "hanseniase"))
    author = User.create!(email_address: "author-#{SecureRandom.hex(3)}@example.org", password: "secret123")
    maintainer = Maintainer.create!(email_address: "gm-#{SecureRandom.hex(3)}@rotasaude.app", password: "s3nha-forte-1",
                                    otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)

    ProtocolContribution.create!(protocol_definition: pd, actor_id: author.id, actor_kind: "user",
                                 content_digest: pd.content_digest)
    ProtocolContribution.create!(protocol_definition: pd, actor_id: maintainer.id, actor_kind: "maintainer",
                                 content_digest: pd.content_digest)

    get "/admin/api/protocols/hanseniase"
    expect(response).to have_http_status(:ok)

    editors = json["data"]["versions"].find { |v| v["version"] == "1" }["editors"]
    expect(editors).to match_array([
      { "kind" => "user", "id" => author.id, "email" => author.email_address },
      { "kind" => "maintainer", "id" => maintainer.id, "email" => nil }
    ])
  end

  it "revertible é falso só com a linha-base e verdadeiro depois de uma ativação assinada sobre ela" do
    legacy = ProtocolDefinition.create!(name: "sarampo", version: 1, status: "active",
                                        definition: protocol_definition_hash(name: "sarampo"))
    legacy.activations.create!(kind: "baseline", actor_kind: "system", actor_id: nil)

    get "/admin/api/protocols/sarampo"
    v1 = json["data"]["versions"].find { |v| v["version"] == "1" }
    expect(v1["revertible"]).to be(false)

    v2 = ProtocolDefinition.create!(name: "sarampo", version: 2, status: "published",
                                    definition: protocol_definition_hash(name: "sarampo", version: 2))
    ana = make_reviewer!
    bia = make_reviewer!
    sign!(v2, purpose: "activation", by: ana)
    sign!(v2, purpose: "activation", by: bia)
    publisher = User.create!(email_address: "pub-#{SecureRandom.hex(3)}@example.org", password: "secret123").tap do |u|
      Membership.create!(user: u, role: "protocol_publisher", granted_at: Time.current)
    end
    expect(Protocols::Activate.call(version: 2, name: "sarampo", by: publisher).ok?).to be(true)

    get "/admin/api/protocols/sarampo"
    v2_after = json["data"]["versions"].find { |v| v["version"] == "2" }
    v1_after = json["data"]["versions"].find { |v| v["version"] == "1" }
    expect(v2_after["revertible"]).to be(true)
    expect(v1_after["revertible"]).to be(false)
  end

  it "mantém createdBy, publishedBy e fourEyes com o mesmo significado de antes" do
    ProtocolDefinition.create!(name: "zika", version: 1, status: "draft",
                              definition: protocol_definition_hash(name: "zika"))

    get "/admin/api/protocols/zika"
    version = json["data"]["versions"].find { |v| v["version"] == "1" }

    expect(version).to have_key("createdBy")
    expect(version).to have_key("publishedBy")
    expect(version).to have_key("fourEyes")
    expect(version["fourEyes"]).to be_nil # nenhum audit event: nem created_by nem published_by
  end

  it "a montagem dos campos novos não consulta domain_events" do
    pd = ProtocolDefinition.create!(name: "chikungunya", version: 1, status: "in_review",
                                    definition: protocol_definition_hash(name: "chikungunya"))

    expect(DomainEvent).not_to receive(:where)

    Admin::ProtocolsQuery.signature_state(pd)
  end

  it "index (GET /admin/api/protocols) também traz os campos novos por linha" do
    ProtocolDefinition.create!(name: "coqueluche", version: 1, status: "in_review",
                              definition: protocol_definition_hash(name: "coqueluche"))

    get "/admin/api/protocols"
    expect(response).to have_http_status(:ok)

    row = json["data"]["list"].find { |r| r["name"] == "coqueluche" }
    expect(row["signatures"]).to eq(
      "publication" => { "signers" => [], "missing" => 2 },
      "activation" => { "signers" => [], "missing" => 2 }
    )
    expect(row["eligibleReviewers"]).to eq(0)
    expect(row["editors"]).to eq([])
    expect(row["revertible"]).to be(false)
  end
end
