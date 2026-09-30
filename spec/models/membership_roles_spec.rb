require "rails_helper"

RSpec.describe Membership do
  it "conhece o papel citizen_verifier e o trata como privilegiado" do
    expect(described_class::ROLES).to include("citizen_verifier")
    expect(described_class::PRIVILEGED_ROLES).to include("citizen_verifier")
  end

  it "o banco aceita o papel" do
    user = User.create!(email_address: "atendente@cidade.gov.br", password: "senha-segura-123")
    expect { described_class.create!(user: user, role: "citizen_verifier", granted_at: Time.current) }.not_to raise_error
  end

  it "conhece o papel health_professional e o trata como privilegiado" do
    expect(described_class::ROLES).to include("health_professional")
    expect(described_class::PRIVILEGED_ROLES).to include("health_professional")
    user = User.create!(email_address: "medica@cidade.gov.br", password: "senha-segura-123")
    expect { described_class.create!(user: user, role: "health_professional", granted_at: Time.current) }.not_to raise_error
  end

  it "conhece o papel campaign_manager e o trata como privilegiado (ADR 0024)" do
    expect(described_class::ROLES).to include("campaign_manager")
    expect(described_class::PRIVILEGED_ROLES).to include("campaign_manager")
    user = User.create!(email_address: "campanhas@cidade.gov.br", password: "senha-segura-123")
    expect { described_class.create!(user: user, role: "campaign_manager", granted_at: Time.current) }.not_to raise_error
  end

  it "conhece o papel analyst e NÃO o trata como privilegiado (ADR 0025)" do
    expect(described_class::ROLES).to include("analyst")
    expect(described_class::PRIVILEGED_ROLES).not_to include("analyst")
    user = User.create!(email_address: "analise@cidade.gov.br", password: "senha-segura-123")
    expect { described_class.create!(user: user, role: "analyst", granted_at: Time.current) }.not_to raise_error
  end
end
