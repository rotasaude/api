require "rails_helper"

# Cobre o seam de gov.br: lookup/criação de User+Identity, audit, assurance.
# fetch_token e decode_id_token reais usam HTTP e JWT — testáveis via webmock
# + chave RSA fake em outro spec; aqui mockamos exchange_code_for_claims.
RSpec.describe Authenticator::GovBr do
  self.use_transactional_tests = false

  before do
    ApplicationRecord.connected_to(role: :admin) do
      ApplicationRecord.connection.execute("DELETE FROM identities")
      ApplicationRecord.connection.execute("DELETE FROM users")
    end
    Current.reset
  end

  after do
    ApplicationRecord.connected_to(role: :admin) do
      ApplicationRecord.connection.execute("DELETE FROM identities")
      ApplicationRecord.connection.execute("DELETE FROM users")
    end
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
        allow(Platform).to receive(:audit)
      end

      it "cria User + Identity quando nenhum existe" do
        user = described_class.authenticate(code: "valid")
        expect(user).to be_a(User)
        expect(user.email_address).to eq("fulano@gov.br")
        ApplicationRecord.connected_to(role: :admin) do
          expect(Identity.where(provider: "govbr", provider_uid: "12345678900").count).to eq(1)
        end
      end

      it "reusa User existente quando o email bate (seam: 2 identidades para mesmo user)" do
        existing = ApplicationRecord.connected_to(role: :admin) do
          User.create!(email_address: "fulano@gov.br", password: "secret123")
        end
        user = described_class.authenticate(code: "valid")
        expect(user.id).to eq(existing.id)
        ApplicationRecord.connected_to(role: :admin) do
          expect(Identity.where(user: existing, provider: "govbr").count).to eq(1)
        end
      end

      it "reusa User+Identity quando provider_uid já existe (segundo login)" do
        first  = described_class.authenticate(code: "valid")
        second = described_class.authenticate(code: "valid")
        expect(first.id).to eq(second.id)
        ApplicationRecord.connected_to(role: :admin) do
          expect(Identity.where(provider: "govbr", provider_uid: "12345678900").count).to eq(1)
        end
      end

      it "registra Platform.audit com assurance level" do
        expect(Platform).to receive(:audit).with("identity.govbr_login",
          hash_including(provider_uid: "12345678900", assurance: "ouro"))
        described_class.authenticate(code: "valid")
      end

      it "user desativado retorna nil" do
        described_class.authenticate(code: "valid")
        ApplicationRecord.connected_to(role: :admin) do
          User.find_by(email_address: "fulano@gov.br").update!(deactivated_at: Time.current)
        end
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
