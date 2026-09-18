require "rails_helper"

# Spec §8: `city(slug:)` é o ÚNICO caminho para dentro do banco de uma cidade, e
# é onde o escopo do token é aplicado. Teto de 5 cidades por operação.
RSpec.describe "Maintenance city", type: :request do
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

  # P1: a query mora num método, não numa constante de topo — uma constante
  # aqui viveria em Object e colidiria com a CITY/QUERY de outros specs.
  def city_query
    <<~GQL
      query($slug: String!) {
        city(slug: $slug) {
          slug name uf status schemaVersion schemaBehind
          channel { phoneNumberId wabaId displayPhoneNumber active }
        }
      }
    GQL
  end

  # Mesmo padrão de cities_spec.rb: cidade de harness registrada direto no
  # catálogo de plataforma.
  def register_city!(test_city)
    return if City.exists?(slug: test_city.slug)

    City.create!(slug: test_city.slug, name: test_city.name, status: "active",
                database_url: test_city.database_url, encryption_key: test_city.encryption_key,
                schema_version: CitySchema.expected_version.to_s)
  end

  let!(:archived_city) do
    City.create!(slug: "arquivada-#{SecureRandom.hex(3)}", name: "Cidade Arquivada", uf: "sp",
                status: "archived", schema_version: "0",
                # Arquivada não abre conexão — a URL nunca é discada, e é de
                # propósito claramente não roteável.
                database_url: "postgres://unreachable.invalid/none",
                encryption_key: SecureRandom.hex(32))
  end

  # P2: linhas extras só-de-plataforma para o exemplo de 6 cidades. O
  # analisador de teto recusa na ANÁLISE, antes de qualquer resolver abrir
  # conexão (o exemplo abaixo, "refuses an operation that touches more than
  # five cities, before executing it", cobre isso com
  # `expect(CityConnection).not_to receive(:with)`), então uma URL que nunca
  # é discada serve.
  let!(:extra_cities) do
    Array.new(3) do |i|
      City.create!(slug: "extra-#{i}-#{SecureRandom.hex(3)}", name: "Extra #{i}", status: "provisioning",
                  schema_version: "0", database_url: "postgres://unreachable.invalid/extra-#{i}",
                  encryption_key: SecureRandom.hex(32))
    end
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

  it "answers the platform side of a city, never the channel token" do
    gql!(city_query, slug: city.slug)

    answered = json.dig("data", "city")
    # M1: status agora é o enum CityStatus — publicado em maiúsculas.
    expect(answered).to include("slug" => city.slug, "status" => city.status.upcase)
    expect(answered["channel"]&.keys).to satisfy { |keys| keys.nil? || keys.exclude?("accessToken") }
    expect(response.body).not_to include("access_token")
  end

  it "answers nil for a slug that does not exist" do
    gql!(city_query, slug: "cidade-que-nao-existe")

    expect(json.dig("data", "city")).to be_nil
    expect(json["errors"]).to be_nil
  end

  it "refuses a city outside a token's scope, and answers the one inside it" do
    other = City.find_by!(slug: TEST_CITY_B.slug)

    _token, secret = MaintenanceToken.issue!(maintainer: maintainer, name: "ci", access: "read",
                                             city_slugs: [ city.slug ], expires_at: 5.days.from_now)
    bearer = { "Authorization" => "Bearer #{secret}", "Cookie" => "" }

    gql!(city_query, slug: other.slug, headers: bearer)
    expect(json.dig("data", "city")).to be_nil
    expect(json["errors"].first["extensions"]["code"]).to eq("CITY_OUT_OF_SCOPE")

    gql!(city_query, slug: city.slug, headers: bearer)
    expect(json.dig("data", "city", "slug")).to eq(city.slug)
  end

  # P8 (fix round 1, spec §9): "uso recusado de token … fora do escopo"
  # cobre `city(slug:)` também — não só HumanOnly/WriteScope. A auditoria é
  # ÚNICA por requisição recusada (mesmo caminho de token_auth_spec.rb), e o
  # slug PEDIDO nunca aparece no evento — só o nome do campo (`city`).
  it "audits a token refused outside its city scope, and nothing else" do
    other = City.find_by!(slug: TEST_CITY_B.slug)
    _token, secret = MaintenanceToken.issue!(maintainer: maintainer, name: "ci", access: "read",
                                             city_slugs: [ city.slug ], expires_at: 5.days.from_now)
    bearer = { "Authorization" => "Bearer #{secret}", "Cookie" => "" }
    refused = PlatformEvent.where(name: "maintenance.token.refused")

    expect { gql!(city_query, slug: other.slug, headers: bearer) }.to change { refused.count }.by(1)

    event = refused.last.payload
    expect(event).to include("outcome" => "rejected", "module" => "token", "refused_fields" => [ "city" ])
    expect(event.to_json).not_to include(other.slug)
  end

  it "writes no refusal for an in-scope city, or for a human session" do
    _token, secret = MaintenanceToken.issue!(maintainer: maintainer, name: "ci", access: "read",
                                             city_slugs: [ city.slug ], expires_at: 5.days.from_now)
    bearer = { "Authorization" => "Bearer #{secret}", "Cookie" => "" }
    refused = PlatformEvent.where(name: "maintenance.token.refused")

    expect { gql!(city_query, slug: city.slug, headers: bearer) }.not_to change { refused.count }
    expect { gql!(city_query, slug: city.slug) }.not_to change { refused.count }
  end

  it "refuses an operation that touches more than five cities, before executing it" do
    slugs = City.order(:slug).limit(6).pluck(:slug)
    expect(slugs.size).to eq(6)

    query = "{ " + slugs.each_with_index.map { |s, i| "c#{i}: city(slug: \"#{s}\") { slug }" }.join(" ") + " }"
    expect(CityConnection).not_to receive(:with)

    gql!(query)

    expect(json["errors"].first["extensions"]["code"]).to eq("CITY_BUDGET_EXCEEDED")
    expect(json["data"]).to be_nil
  end

  it "counts aliases and fragments toward the same budget" do
    slug = city.slug
    query = <<~GQL
      { a: city(slug: "#{slug}") { ...s } b: city(slug: "#{slug}") { ...s } c: city(slug: "#{slug}") { ...s }
        d: city(slug: "#{slug}") { ...s } e: city(slug: "#{slug}") { ...s } f: city(slug: "#{slug}") { ...s } }
      fragment s on City { slug }
    GQL

    gql!(query)

    expect(json["errors"].first["extensions"]["code"]).to eq("CITY_BUDGET_EXCEEDED")
  end

  # (fix round 1) Sem linha nenhuma nas tabelas de cidade o happy-path nunca
  # exercitava a projeção sensível de `accounts` (email, papel ativo, MFA) nem
  # `protocols`/`alertRecipients` — arranja uma linha de cada, dentro da MESMA
  # sessão de TEST_CITY_A que o harness já abriu, e verifica VALORES, não só
  # presença de chave.
  it "answers the configuration inside the city's database" do
    password = "s3nha-staff-1"
    otp_secret = ROTP::Base32.random
    staff = User.create!(email_address: "staff-#{SecureRandom.hex(3)}@cidade.gov.br", password: password,
                         otp_secret: otp_secret, otp_enabled: true)
    Membership.create!(user: staff, role: "municipal_admin", granted_at: 2.days.ago)
    Membership.create!(user: staff, role: "protocol_author", granted_at: 2.days.ago, revoked_at: 1.day.ago)

    CityProfile.create!(name: "Cidade Teste", uf: "PR", ibge_code: "4106902")
    AlertRecipient.create!(channel: "email", destination: "secretaria@cidade.gov.br",
                           active: true, escalation_order: 1)
    ProtocolDefinition.create!(name: "config-demo", version: 1, status: "active", definition: {
      "name" => "config-demo", "version" => 1, "start_step_id" => "s1",
      "steps" => [ { "id" => "s1", "prompt" => "?", "answer_type" => "boolean",
                    "branches" => { "true" => nil, "false" => nil } } ],
      "scoring" => { "type" => "weighted", "thresholds" => { "baixa" => 0 } }
    })

    query = <<~GQL
      query($slug: String!) {
        city(slug: $slug) {
          profile { name uf ibgeCode }
          protocols { name version status }
          alertRecipients { channel destination escalationOrder }
          accounts { login roles active mfaEnrolled }
        }
      }
    GQL

    gql!(query, slug: city.slug)

    answered = json.dig("data", "city")
    expect(json["errors"]).to be_nil
    expect(answered["profile"]).to eq("name" => "Cidade Teste", "uf" => "PR", "ibgeCode" => "4106902")
    expect(answered["protocols"]).to include("name" => "config-demo", "version" => 1, "status" => "active")
    expect(answered["alertRecipients"]).to include(
      "channel" => "email", "destination" => "secretaria@cidade.gov.br", "escalationOrder" => 1
    )
    staff_account = answered["accounts"].find { |a| a["login"] == staff.email_address }
    expect(staff_account).to include("roles" => [ "municipal_admin" ], "active" => true, "mfaEnrolled" => true)
  end

  # (fix round 1, ruling P9) `consent_terms.version` é STRING no banco da
  # cidade — o campo não pode reimplementar "qual é a versão vigente", tem de
  # responder exatamente o que `Consents.current_version` (o resto do app)
  # trata como atual, seja lá qual for o resultado do MAX lexicográfico.
  it "answers the consent term version exactly as the domain's Consents.current_version does" do
    ConsentTerm.create!(version: "9", body: "termo", published_at: Time.current)
    ConsentTerm.create!(version: "10", body: "termo", published_at: Time.current)
    expected = Consents.current_version
    expect(expected).to be_a(String)

    gql!('query($slug: String!) { city(slug: $slug) { consentTermVersion } }', slug: city.slug)

    expect(json.dig("data", "city", "consentTermVersion")).to eq(expected)
  end

  it "reports an unreachable city as a field error, redacted, without failing the operation" do
    other = City.active.where.not(id: city.id).order(:slug).first
    skip "harness com uma cidade ativa só" if other.nil?

    # O harness de `city:test_databases` só carrega o schema, sem seed — sem
    # isto `profile` de uma cidade que RESPONDEU seria nil por falta de linha,
    # e não provaria a diferença entre "respondeu com sucesso" e "falhou". A
    # exemplo já roda dentro da sessão de TEST_CITY_A (ver cabeçalho de
    # spec/support/city_test_databases.rb), então a linha é visível ao resolver.
    CityProfile.create!(name: "Cidade Teste", uf: "PR", ibge_code: "4106902")

    allow(Maintenance::CityReader).to receive(:call).and_call_original
    allow(Maintenance::CityReader).to receive(:call).with(having_attributes(slug: other.slug))
      .and_raise(Maintenance::CityReader::Unreachable, "PG::ConnectionBad: connection to ://***@db failed")

    query = <<~GQL
      { ok: city(slug: "#{city.slug}") { profile { name } }
        bad: city(slug: "#{other.slug}") { profile { name } } }
    GQL
    gql!(query)

    expect(json.dig("data", "ok", "profile")).not_to be_nil
    expect(json.dig("data", "bad", "profile")).to be_nil
    error = json["errors"].find { |e| e["path"]&.include?("bad") }
    expect(error["extensions"]["code"]).to eq("CITY_UNREACHABLE")
    expect(error["message"]).to include("://***@")
  end

  it "answers CITY_ARCHIVED for the inner fields of an archived city, and still answers the platform ones" do
    archived = City.where(status: "archived").order(:slug).first
    skip "nenhuma cidade arquivada no harness" if archived.nil?

    gql!('query($slug: String!) { city(slug: $slug) { slug status profile { name } } }', slug: archived.slug)

    expect(json.dig("data", "city", "status")).to eq("ARCHIVED")
    expect(json.dig("data", "city", "profile")).to be_nil
    expect(json["errors"].first["extensions"]["code"]).to eq("CITY_ARCHIVED")
  end

  # (fix round 1) Sem uma conta de verdade, os nomes proibidos nunca podiam
  # aparecer de qualquer forma — a checagem provava só ausência de campo, não
  # ausência de SEGREDO. Arranja um usuário com senha e OTP de verdade e prova
  # que o digest e o segredo em si (não só o nome da chave) ficam fora.
  it "never answers citizen content or a secret from inside the city" do
    otp_secret = ROTP::Base32.random
    staff = User.create!(email_address: "staff-#{SecureRandom.hex(3)}@cidade.gov.br", password: "s3nha-staff-1",
                         otp_secret: otp_secret, otp_enabled: true)
    digest = staff.password_digest

    query = <<~GQL
      query($slug: String!) { city(slug: $slug) { accounts { login } alertRecipients { destination } } }
    GQL

    gql!(query, slug: city.slug)

    expect(json.dig("data", "city", "accounts")).to include(include("login" => staff.email_address))

    %w[password_digest otp_secret database_url encryption_key access_token].each do |forbidden|
      expect(response.body).not_to include(forbidden)
    end
    expect(response.body).not_to include(digest)
    expect(response.body).not_to include(otp_secret)
  end
end
