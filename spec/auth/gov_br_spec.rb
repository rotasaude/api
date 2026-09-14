require "rails_helper"

# Seam do gov.br (ADR-0011), depois do callback único em auth.* (Plano 3B):
# state assinado com cidade + nonce, troca do code, e provisionamento do usuário
# NA cidade corrente. fetch_token e decode_id_token reais usam HTTP e JWT; aqui a
# troca é mockada.
RSpec.describe Authenticator::GovBr do
  include ActiveSupport::Testing::TimeHelpers

  let(:city) { City.new(slug: TEST_CITY_A.slug) }

  before do
    Current.reset
    Current.city = TEST_CITY_A # identity.govbr_login é evento DA CIDADE (Ruling R18)
    allow(described_class).to receive_messages(
      client_id: "rota-client", redirect_uri: "https://auth.rotasaude.app/auth/govbr/callback",
      issuer_url: "https://sso.staging.acesso.gov.br"
    )
  end

  after { Current.reset }

  describe ".start and .verify_state" do
    def query_of(url) = Rack::Utils.parse_query(URI.parse(url).query)

    it "builds the authorize URL with a signed state carrying the city and the same nonce" do
      url = described_class.start(city: city)

      expect(url).to start_with("https://sso.staging.acesso.gov.br/authorize?")
      query = query_of(url)
      expect(query).to include("response_type" => "code", "client_id" => "rota-client", "scope" => "openid email profile",
                               "redirect_uri" => "https://auth.rotasaude.app/auth/govbr/callback")
      state = described_class.verify_state(query.fetch("state"))
      expect(state).to eq("city" => TEST_CITY_A.slug, "nonce" => query.fetch("nonce"))
    end

    it "uses a fresh nonce on every start" do
      first = query_of(described_class.start(city: city)).fetch("nonce")
      second = query_of(described_class.start(city: city)).fetch("nonce")

      expect(first).not_to eq(second)
    end

    it "refuses a tampered, expired, blank or non-string state" do
      state = query_of(described_class.start(city: city)).fetch("state")

      expect(described_class.verify_state("#{state}x")).to be_nil
      expect(described_class.verify_state("")).to be_nil
      expect(described_class.verify_state([ state ])).to be_nil
      travel 11.minutes do
        expect(described_class.verify_state(state)).to be_nil
      end
    end
  end

  describe ".exchange_code_for_claims" do
    it "code vazio levanta IntegrationError" do
      expect { described_class.exchange_code_for_claims("") }.to raise_error(Authenticator::GovBr::IntegrationError, /vazio/)
    end
  end

  describe "configuração ausente/vazia" do
    it "GOVBR_CLIENT_ID vazio conta como ausente (start levanta IntegrationError)" do
      allow(described_class).to receive(:client_id).and_call_original
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("GOVBR_CLIENT_ID").and_return("")

      expect { described_class.start(city: city) }.to raise_error(Authenticator::GovBr::IntegrationError, /GOVBR_CLIENT_ID/)
    end
  end

  describe ".provision_from_claims" do
    let(:claims) do
      { "sub" => "12345678900", "email" => "fulano@gov.br", "name" => "Fulano de Tal", "amr" => [ "ouro" ],
       "email_verified" => true }
    end

    it "cria User + Identity quando nenhum existe" do
      user = described_class.provision_from_claims(claims)

      expect(user).to be_a(User)
      expect(user.email_address).to eq("fulano@gov.br")
      expect(Identity.where(provider: "govbr", provider_uid: "12345678900").count).to eq(1)
    end

    it "reusa User existente quando o email bate (seam: 2 identidades para mesmo user)" do
      existing = User.create!(email_address: "fulano@gov.br", password: "secret123")
      claims["email_verified"] = true

      user = described_class.provision_from_claims(claims)

      expect(user.id).to eq(existing.id)
      expect(Identity.where(user: existing, provider: "govbr").count).to eq(1)
    end

    it "não liga a conta existente quando o email não é verificado" do
      existing = User.create!(email_address: "fulano@gov.br", password: "secret123")
      claims["email_verified"] = false

      expect(described_class.provision_from_claims(claims)).to be_nil
      expect(Identity.where(user: existing, provider: "govbr")).to be_empty
    end

    it "cria usuário com email placeholder quando o email não é verificado e ninguém o usa" do
      claims["email_verified"] = false

      user = described_class.provision_from_claims(claims)

      expect(user).to be_a(User)
      expect(user.email_address).to eq("govbr-12345678900@placeholder.invalid")
      expect(User.where(email_address: "fulano@gov.br")).to be_empty
      expect(Identity.where(provider: "govbr", provider_uid: "12345678900").count).to eq(1)
    end

    it "reusa User+Identity quando provider_uid já existe (segundo login)" do
      first  = described_class.provision_from_claims(claims)
      second = described_class.provision_from_claims(claims)

      expect(first.id).to eq(second.id)
      expect(Identity.where(provider: "govbr", provider_uid: "12345678900").count).to eq(1)
    end

    it "grava um DomainEvent identity.govbr_login com assurance level, na cidade (Ruling R18), nunca na plataforma" do
      user = nil
      expect { user = described_class.provision_from_claims(claims) }.not_to change(PlatformEvent, :count)

      event = DomainEvent.find_by!(name: "identity.govbr_login")
      expect(event.payload).to include("user_id" => user.id, "provider_uid" => "12345678900", "assurance" => "ouro")
    end

    it "grava o DomainEvent com assurance nil quando os claims não trazem amr nem nivel_confianca" do
      claims.delete("amr")

      user = described_class.provision_from_claims(claims)

      event = DomainEvent.find_by!(name: "identity.govbr_login")
      expect(event.payload).to include("user_id" => user.id, "assurance" => nil)
    end

    it "user desativado retorna nil" do
      described_class.provision_from_claims(claims)
      User.find_by(email_address: "fulano@gov.br").update!(deactivated_at: Time.current)

      expect(described_class.provision_from_claims(claims)).to be_nil
    end

    it "id_token sem sub levanta IntegrationError" do
      claims.delete("sub")

      expect { described_class.provision_from_claims(claims) }
        .to raise_error(Authenticator::GovBr::IntegrationError, /sub/)
    end
  end

  describe ".assurance_meets?" do
    it "bronze cobre só viewer" do
      expect(described_class.assurance_meets?(assurance: "bronze", role: "viewer")).to be true
      expect(described_class.assurance_meets?(assurance: "bronze", role: "municipal_admin")).to be false
      expect(described_class.assurance_meets?(assurance: "bronze", role: "platform_operator")).to be false
    end

    it "prata cobre viewer e municipal_admin (mas não publisher/operator)" do
      expect(described_class.assurance_meets?(assurance: "prata", role: "viewer")).to be true
      expect(described_class.assurance_meets?(assurance: "prata", role: "municipal_admin")).to be true
      expect(described_class.assurance_meets?(assurance: "prata", role: "protocol_publisher")).to be false
    end

    it "ouro cobre todos" do
      expect(described_class.assurance_meets?(assurance: "ouro", role: "viewer")).to be true
      expect(described_class.assurance_meets?(assurance: "ouro", role: "protocol_publisher")).to be true
      expect(described_class.assurance_meets?(assurance: "ouro", role: "platform_operator")).to be true
    end

    it "assurance ou role nil/inválido devolve false" do
      expect(described_class.assurance_meets?(assurance: nil, role: "viewer")).to be false
      expect(described_class.assurance_meets?(assurance: "diamante", role: "viewer")).to be false
      expect(described_class.assurance_meets?(assurance: "ouro", role: nil)).to be false
    end
  end
end
