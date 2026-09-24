require "rails_helper"

# Leitura do ciclo de vida para as telas de escrita (Plano 2 do frontend de
# manutenção): TODAS as versões, com o estado de assinatura calculado pelas
# mesmas funções de domínio que os commands usam. Só contagens — nenhum
# e-mail nem id de revisor sai por aqui.
RSpec.describe "Maintenance city protocolVersions", type: :request do
  let(:frontend) { "https://maintenance.rotasaude.app" }
  let(:password) { "s3nha-forte-1" }
  let!(:maintainer) do
    Maintainer.create!(email_address: "cy-#{SecureRandom.hex(3)}@rotasaude.app", password: password,
                       otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
  end

  def browser = { "Origin" => frontend, "X-Rota-Maintenance" => "1" }
  def json = JSON.parse(response.body)

  def login!
    post "/session", params: { email_address: maintainer.email_address, password: password }, headers: browser
    post "/session/challenge", params: { session_id: json["session_id"], code: ROTP::TOTP.new(maintainer.otp_secret).now },
         headers: browser
    expect(response).to have_http_status(:ok)
  end

  def gql!(query, headers: browser, **variables)
    post "/graphql", params: { query: query, variables: variables.to_json }, headers: headers
  end

  # Mesmo padrão de city_spec.rb: cidade de harness registrada direto no
  # catálogo de plataforma.
  def register_city!(test_city)
    return if City.exists?(slug: test_city.slug)

    City.create!(slug: test_city.slug, name: test_city.name, status: "active",
                database_url: test_city.database_url, encryption_key: test_city.encryption_key,
                schema_version: CitySchema.expected_version.to_s)
  end

  let(:city) { City.find_by!(slug: TEST_CITY_A.slug) }

  before do
    register_city!(TEST_CITY_A)
    register_city!(TEST_CITY_B)
    host! "maintenance-api.rotasaude.app"
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with(MaintenanceApi::ORIGIN).and_return(frontend)
    login!
  end

  def versions_query
    <<~GQL
      query($slug: String!) {
        city(slug: $slug) {
          protocolVersions {
            name version status
            publicationSignatures publicationMissing
            activationSignatures activationMissing
            eligibleReviewers revertible revertTargetVersion
          }
        }
      }
    GQL
  end

  def versions = json.dig("data", "city", "protocolVersions")
  def row(name, version) = versions.find { |v| v["name"] == name && v["version"] == version }

  def create_version!(status:, version: 1, name: "dengue")
    ProtocolDefinition.create!(name: name, version: version, status: status,
                               definition: protocol_definition_hash(name: name, version: version))
  end

  it "lista versões em todo status, não só a ativa" do
    %w[draft in_review published retired].each_with_index do |status, i|
      create_version!(status: status, version: i + 1)
    end

    gql!(versions_query, slug: city.slug)

    expect(json["errors"]).to be_nil
    expect(versions.map { |v| [ v["version"], v["status"] ] })
      .to eq([ [ 3, "published" ], [ 2, "in_review" ], [ 1, "draft" ], [ 4, "retired" ] ])
  end

  # A1: sem o CASE de status, order(:name, version: :desc) sozinho intercalaria
  # aposentadas com vivas — "amarelo" (aposentada) viria ANTES de "zika" (viva)
  # e, sob o teto de 100, poderia empurrar uma versão viva para fora da
  # resposta. Aqui "amarelo" tem o nome que ordenaria primeiro e "zika" o que
  # ordenaria por último — e mesmo assim a aposentada sai depois da viva.
  it "nunca deixa uma aposentada de nome anterior sair antes de uma viva de nome posterior" do
    create_version!(name: "amarelo", status: "retired", version: 1)
    create_version!(name: "zika", status: "draft", version: 1)

    gql!(versions_query, slug: city.slug)

    expect(json["errors"]).to be_nil
    expect(versions.map { |v| [ v["name"], v["status"] ] })
      .to eq([ [ "zika", "draft" ], [ "amarelo", "retired" ] ])
  end

  it "conta assinaturas válidas e o que falta por finalidade" do
    protocol = create_version!(status: "in_review")
    reviewers = Array.new(3) { make_reviewer! }
    sign!(protocol, purpose: "publication", by: reviewers.first)

    gql!(versions_query, slug: city.slug)

    expect(row("dengue", 1)).to include(
      "publicationSignatures" => 1, "publicationMissing" => 1,
      "activationSignatures" => 0, "activationMissing" => 2,
      "eligibleReviewers" => 3, "revertible" => false, "revertTargetVersion" => nil
    )
  end

  it "responde o mesmo que o domínio para faltantes e revisores elegíveis" do
    protocol = create_version!(status: "in_review")
    2.times { make_reviewer! }

    gql!(versions_query, slug: city.slug)

    expect(row("dengue", 1)["publicationMissing"])
      .to eq(Protocols::Signatures.missing(protocol, purpose: "publication"))
    expect(row("dengue", 1)["eligibleReviewers"])
      .to eq(Protocols::Signatures.eligible_reviewer_count(protocol))
  end

  it "não expõe e-mail nem id de revisor" do
    protocol = create_version!(status: "in_review")
    reviewer = make_reviewer!
    sign!(protocol, purpose: "publication", by: reviewer)

    gql!(versions_query, slug: city.slug)

    expect(response.body).not_to include(reviewer.email_address)
    expect(response.body).not_to include(reviewer.id.to_s)
  end

  it "não tem campo de definição (escopo A: sem editor)" do
    gql!('query($slug: String!) { city(slug: $slug) { protocolVersions { definition } } }', slug: city.slug)

    expect(json["errors"].first["message"]).to include("definition")
  end

  it "responde lista vazia numa cidade sem protocolo" do
    gql!(versions_query, slug: city.slug)

    expect(versions).to eq([])
  end

  # Mesmo arranjo de city_spec.rb ("reports an unreachable city as a field
  # error..."): não simula cidade inalcançável com URL real (memória "Specs
  # não inferem tipo") — troca a resposta de CityReader.call por dublê só
  # para a cidade-alvo. Sem alias na query: o path do erro precisa ser
  # ["city", "protocolVersions"], não ["bad", "protocolVersions"].
  it "reports an unreachable city as a field error on protocolVersions" do
    other = City.active.where.not(id: city.id).order(:slug).first
    skip "harness com uma cidade ativa só" if other.nil?

    allow(Maintenance::CityReader).to receive(:call).and_call_original
    allow(Maintenance::CityReader).to receive(:call).with(having_attributes(slug: other.slug))
      .and_raise(Maintenance::CityReader::Unreachable, "PG::ConnectionBad: connection to ://***@db failed")

    gql!(versions_query, slug: other.slug)

    expect(json.dig("data", "city", "protocolVersions")).to be_nil
    error = json["errors"].first
    expect(error["extensions"]["code"]).to eq("CITY_UNREACHABLE")
    expect(error["path"]).to eq([ "city", "protocolVersions" ])
  end

  # Arranjo de spec/requests/admin/protocols_signatures_spec.rb:68-92: só a
  # versão ativa, depois de uma segunda ativação assinada sobre a linha-base,
  # responde revertible: true — a anterior (agora published de novo) volta a
  # false.
  it "revertible é true só para a versão ativa depois de uma segunda ativação assinada" do
    legacy = ProtocolDefinition.create!(name: "sarampo", version: 1, status: "active",
                                        definition: protocol_definition_hash(name: "sarampo"))
    legacy.activations.create!(kind: "baseline", actor_kind: "system", actor_id: nil)

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

    gql!(versions_query, slug: city.slug)

    expect(json["errors"]).to be_nil
    expect(row("sarampo", 2)["revertible"]).to be(true)
    expect(row("sarampo", 1)["revertible"]).to be(false)
    expect(row("sarampo", 2)["revertTargetVersion"]).to eq(1)
    expect(row("sarampo", 1)["revertTargetVersion"]).to be_nil
  end
end
