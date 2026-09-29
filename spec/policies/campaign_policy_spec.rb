require "rails_helper"

RSpec.describe CampaignPolicy do
  def policy_for(*roles)
    described_class.new(staff_with("p-#{SecureRandom.hex(4)}@cidade.gov.br", *roles), nil)
  end

  it "só campaign_manager monta e envia campanha" do
    expect(policy_for("campaign_manager").manage?).to be(true)
    (Membership::ROLES - %w[campaign_manager]).each do |role|
      expect(policy_for(role).manage?).to be(false), role
    end
  end

  it "a chave de SMS: campaign_manager e municipal_admin leem; só municipal_admin muda" do
    expect(policy_for("campaign_manager")).to have_attributes(read_sms_setting?: true, write_sms_setting?: false)
    expect(policy_for("municipal_admin")).to have_attributes(read_sms_setting?: true, write_sms_setting?: true)
    expect(policy_for("viewer")).to have_attributes(read_sms_setting?: false, write_sms_setting?: false)
  end

  it "sem usuário (sessão de operador por grant): nada" do
    expect(described_class.new(nil, nil))
      .to have_attributes(manage?: false, read_sms_setting?: false, write_sms_setting?: false)
  end
end
