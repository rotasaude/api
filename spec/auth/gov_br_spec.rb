require "rails_helper"

# Cobre o seam de gov.br: lookup/criação de User+Identity, audit, assurance.
# fetch_token e decode_id_token reais usam HTTP e JWT — testáveis via webmock
# + chave RSA fake em outro spec; aqui mockamos exchange_code_for_claims.
RSpec.describe Authenticator::GovBr do
  # identity.govbr_login is a CITY event (Ruling R18: user/identity events live in
  # the city's own domain_events, never on the platform), so DomainEvents.publish
  # needs Current.city set — the harness only opens the connection, it does not
  # set the Current attribute (spec/support/city_test_databases.rb).
  before do
    Current.reset
    Current.city = TEST_CITY_A
  end

  after do
    Current.reset
  end

  describe ".authenticate" do
    it "code vazio levanta IntegrationError" do
      expect { described_class.authenticate(code: "") }.to raise_error(Authenticator::GovBr::IntegrationError, /vazio/)
    end

    context "com exchange mockado" do
      let(:claims) do
        {
          "sub"   => "12345678900",
          "email" => "fulano@gov.br",
          "name"  => "Fulano de Tal",
          "amr"   => ["ouro"]
        }
      end

      before do
        allow(described_class).to receive(:exchange_code_for_claims).and_return(claims)
      end

      it "cria User + Identity quando nenhum existe" do
        user = described_class.authenticate(code: "valid")
        expect(user).to be_a(User)
        expect(user.email_address).to eq("fulano@gov.br")
        expect(Identity.where(provider: "govbr", provider_uid: "12345678900").count).to eq(1)
      end

      it "reusa User existente quando o email bate (seam: 2 identidades para mesmo user)" do
        existing = User.create!(email_address: "fulano@gov.br", password: "secret123")
        user = described_class.authenticate(code: "valid")
        expect(user.id).to eq(existing.id)
        expect(Identity.where(user: existing, provider: "govbr").count).to eq(1)
      end

      it "reusa User+Identity quando provider_uid já existe (segundo login)" do
        first  = described_class.authenticate(code: "valid")
        second = described_class.authenticate(code: "valid")
        expect(first.id).to eq(second.id)
        expect(Identity.where(provider: "govbr", provider_uid: "12345678900").count).to eq(1)
      end

      it "grava um DomainEvent identity.govbr_login com assurance level, na cidade (Ruling R18), nunca na plataforma" do
        user = nil
        expect { user = described_class.authenticate(code: "valid") }.not_to change(PlatformEvent, :count)
        event = DomainEvent.find_by!(name: "identity.govbr_login")
        expect(event.payload).to include("user_id" => user.id, "provider_uid" => "12345678900", "assurance" => "ouro")
      end

      it "user desativado retorna nil" do
        described_class.authenticate(code: "valid")
        User.find_by(email_address: "fulano@gov.br").update!(deactivated_at: Time.current)
        expect(described_class.authenticate(code: "valid")).to be_nil
      end
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
