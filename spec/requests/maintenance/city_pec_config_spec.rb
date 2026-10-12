require "rails_helper"

# Contrato §6: só sessão humana; a chave nunca volta, nem em resposta, nem
# em log, nem em auditoria; as duas escritas auditam o campo.
RSpec.describe "Configuração do PEC na API de manutenção", type: :request do
  include ActiveSupport::Testing::TimeHelpers
  let(:frontend) { "https://maintenance.rotasaude.app" }
  let(:password) { "s3nha-forte-1" }
  let!(:maintainer) do
    Maintainer.create!(email_address: "pec-#{SecureRandom.hex(3)}@rotasaude.app", password: password,
                       otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
  end
  let(:city) { City.find_by!(slug: TEST_CITY_A.slug) }

  def browser = { "Origin" => frontend, "X-Rota-Maintenance" => "1" }
  def json = JSON.parse(response.body)
  def gql!(query, **variables) = post("/graphql", params: { query: query, variables: variables.to_json }, headers: browser)

  def login!
    post "/session", params: { email_address: maintainer.email_address, password: password }, headers: browser
    post "/session/challenge", params: { session_id: json["session_id"], code: ROTP::TOTP.new(maintainer.otp_secret).now },
                               headers: browser
  end

  # O passo do TOTP do login não vale de novo no step-up: copie o
  # `with_fresh_totp` de spec/requests/maintenance/protocol_mutations_spec.rb
  # (o código do passo seguinte ao do login, que roda um minuto atrás).

  # Um código de TOTP vale uma vez, para a conta inteira: avança o relógio
  # 31s (mesmo helper de protocol_mutations_spec.rb).
  def with_fresh_totp
    @totp_clock = (@totp_clock || Time.current) + 31.seconds
    travel_to(@totp_clock) { yield(ROTP::TOTP.new(maintainer.otp_secret).now) }
  end

  before do
    unless City.exists?(slug: TEST_CITY_A.slug)
      City.create!(slug: TEST_CITY_A.slug, name: TEST_CITY_A.name, status: "active", database_url: TEST_CITY_A.database_url,
                   encryption_key: TEST_CITY_A.encryption_key, schema_version: CitySchema.expected_version.to_s)
    end
    host! "maintenance-api.rotasaude.app"
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with(MaintenanceApi::ORIGIN).and_return(frontend)
    travel_to(1.minute.ago) { login! }
  end
  after { CityCatalog.reset_cache! }

  it "grava origem e chave, lê sem a chave, audita o campo e não loga a chave" do
    gql!(<<~GQL, citySlug: city.slug, pecOrigin: "https://PEC.cidade.gov.br")
      mutation($citySlug: String!, $pecOrigin: String) { setCityPecOrigin(citySlug: $citySlug, pecOrigin: $pecOrigin) { ok errors { path message } } }
    GQL
    expect(json.dig("data", "setCityPecOrigin")).to eq("ok" => true, "errors" => [])
    gql!(<<~GQL, citySlug: city.slug, key: "chave-do-pec-MARCADOR-0123456789", code: "000000")
      mutation($citySlug: String!, $key: String!, $code: String!) { rotateCityPecHmacKey(citySlug: $citySlug, key: $key, code: $code) { ok errors { path message } } }
    GQL
    expect(json.dig("data", "rotateCityPecHmacKey", "ok")).to be(false)
    expect(PecSetting.current.hmac_key_configured?).to be(false)
    log = capture_log do
      with_fresh_totp do |code|
        gql!(<<~GQL, citySlug: city.slug, key: "chave-do-pec-MARCADOR-0123456789", code: code)
          mutation($citySlug: String!, $key: String!, $code: String!) { rotateCityPecHmacKey(citySlug: $citySlug, key: $key, code: $code) { ok errors { path message } } }
        GQL
      end
    end
    expect(json.dig("data", "rotateCityPecHmacKey", "ok")).to be(true)
    expect(log).not_to include("MARCADOR")
    gql!(<<~GQL, citySlug: city.slug)
      query($citySlug: String!) { cityPecConfig(citySlug: $citySlug) { pecOrigin hmacKeyConfigured hmacKeyUpdatedAt } }
    GQL
    expect(json.dig("data", "cityPecConfig")).to include("pecOrigin" => "https://pec.cidade.gov.br", "hmacKeyConfigured" => true)
    expect(response.body).not_to include("MARCADOR")
    expect(PlatformEvent.where(name: "city.pec_config_changed").order(:created_at).map { |e| e.payload["field"] })
      .to eq(%w[pec_origin hmac_key])
    expect(PlatformEvent.where(name: "maintenance.city.pec_config_changed").order(:created_at).pluck(Arel.sql("payload->>'outcome'")))
      .to eq(%w[attempted ok attempted rejected attempted ok])
    expect(PlatformEvent.where("payload::text LIKE ?", "%MARCADOR%")).to be_empty
  end

  it "valores inválidos: erro no campo, nada gravado, sem city.pec_config_changed" do
    gql!(<<~GQL, citySlug: city.slug, pecOrigin: "https://pec.cidade.gov.br/esus")
      mutation($citySlug: String!, $pecOrigin: String) { setCityPecOrigin(citySlug: $citySlug, pecOrigin: $pecOrigin) { ok errors { path message } } }
    GQL
    expect(json.dig("data", "setCityPecOrigin")).to eq("ok" => false, "errors" => [ { "path" => "pecOrigin", "message" => "invalid_origin" } ])
    with_fresh_totp do |code|
      gql!(<<~GQL, citySlug: city.slug, key: "curta", code: code)
        mutation($citySlug: String!, $key: String!, $code: String!) { rotateCityPecHmacKey(citySlug: $citySlug, key: $key, code: $code) { ok errors { path message } } }
      GQL
    end
    expect(json.dig("data", "rotateCityPecHmacKey")).to eq("ok" => false, "errors" => [ { "path" => "key", "message" => "invalid_key" } ])
    expect(PecSetting.current).to be_nil
    expect(PlatformEvent.where(name: "city.pec_config_changed")).to be_empty
  end

  def read_pec_config!(slug)
    gql!(<<~GQL, citySlug: slug)
      query($citySlug: String!) { cityPecConfig(citySlug: $citySlug) { pecOrigin hmacKeyConfigured hmacKeyUpdatedAt } }
    GQL
  end

  it "cityPecConfig de cidade inexistente: null, sem erro" do
    read_pec_config!("cidade-que-nao-existe")
    expect(json["errors"]).to be_nil
    expect(json["data"]).to eq("cityPecConfig" => nil)
  end

  it "cityPecConfig de cidade inalcançável: erro GraphQL com CITY_UNREACHABLE" do
    allow(Maintenance::CityReader).to receive(:call).and_raise(Maintenance::CityReader::Unreachable, "PG::ConnectionBad: x")
    read_pec_config!(city.slug)
    expect(json.dig("data", "cityPecConfig")).to be_nil
    expect(json["errors"].map { |e| e.dig("extensions", "code") }.uniq).to eq([ "CITY_UNREACHABLE" ])
  end

  describe "token de serviço" do
    def token_execute(query, variables)
      token, = MaintenanceToken.issue!(maintainer: maintainer, name: "ci", access: "read_write",
                                       city_slugs: [ city.slug ], expires_at: 10.days.from_now)
      credential = Maintenance::Credential.token(token)
      Maintenance::Schema.execute(query, variables: variables,
                                         context: { maintainer: maintainer, credential: credential,
                                                    request_id: SecureRandom.uuid }).to_h
    end

    it "é recusado em cityPecConfig, setCityPecOrigin e rotateCityPecHmacKey, sem abrir a cidade nem gravar" do
      allow(Maintenance::CityReader).to receive(:call).and_call_original
      allow(Maintenance::CityWriter).to receive(:call).and_call_original
      operations = {
        "query($citySlug: String!) { cityPecConfig(citySlug: $citySlug) { hmacKeyConfigured } }" => {},
        "mutation($citySlug: String!, $pecOrigin: String) { setCityPecOrigin(citySlug: $citySlug, pecOrigin: $pecOrigin) { ok } }" =>
          { "pecOrigin" => "https://pec.cidade.gov.br" },
        "mutation($citySlug: String!, $key: String!, $code: String!) { rotateCityPecHmacKey(citySlug: $citySlug, key: $key, code: $code) { ok } }" =>
          { "key" => "chave-do-pec-0123456789", "code" => "000000" }
      }
      operations.each do |query, extra|
        result = token_execute(query, { "citySlug" => city.slug }.merge(extra))
        expect(result["data"]).to be_nil
        expect(result["errors"].map { |e| e["message"] }).to include(a_string_matching(/token de serviço não alcança/))
      end
      expect(Maintenance::CityReader).not_to have_received(:call)
      expect(Maintenance::CityWriter).not_to have_received(:call)
      expect(PecSetting.current).to be_nil
    end
  end
end
