require "rails_helper"

RSpec.describe ProvisionMunicipality do
  let!(:operator) do
    u = User.create!(email_address: "op@example.org", password: "secret123")
    Membership.create!(user: u, role: "platform_operator", granted_at: Time.current)
    u
  end

  let(:args) do
    {
      name: "Cidade Teste", ibge_code: "3550308", slug: "cidade-teste", uf: "SP",
      channel: { phone_number_id: "PN1", waba_id: "WABA1", display_phone_number: "+5511", access_token: "tok" },
      admin_email: "admin@cidade.gov.br", invited_by: operator,
      terms: { version: "v1", body: "Termo..." },
      alert: [{ channel: "email", destination: "ops@cidade.gov.br", escalation_order: 0 }]
    }
  end

  # Platform.audit grava DomainEvent com municipality_id: nil, que falha a
  # RLS WITH CHECK em test (rota_app). Mockar globalmente; o test 2 sobrepõe
  # com expect(...).to receive(...).
  before { allow(Platform).to receive(:audit) }

  it "cria município + canal + convite + termos + alerta numa transação coerente" do
    res = described_class.call(**args)
    expect(res.ok?).to be true
    muni = res.payload[:municipality]

    ApplicationRecord.connected_to(role: :admin) do
      expect(Municipality.find(muni.id).status).to eq("active")
      expect(MunicipalityChannel.where(municipality: muni).count).to eq(1)
      expect(Invitation.where(email: "admin@cidade.gov.br").count).to eq(1)
      expect(ConsentTerm.where(municipality_id: muni.id).count).to eq(1)
      expect(AlertRecipient.where(municipality_id: muni.id).count).to eq(1)
    end
  end

  it "emite Platform.audit municipality.provisioned (platform-scope)" do
    expect(Platform).to receive(:audit).with("municipality.provisioned", hash_including(ibge_code: "3550308"))
    described_class.call(**args)
  end
end
