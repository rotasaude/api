require "rails_helper"

RSpec.describe Campaigns::SmsText do
  let(:link) { "#{CityPublicUrl.wpda_base_for_slug(TEST_CITY_A.slug)}/wpda/avisos" }

  it "texto fixo com o nome do perfil da cidade e o link da caixa, sem identificador" do
    CityProfile.create!(name: "Curitiba")
    expect(described_class.body(TEST_CITY_A))
      .to eq("Secretaria de Saúde de Curitiba: você tem um aviso novo. Acesse #{link}")
    expect(described_class.link(TEST_CITY_A)).to eq(link)
  end

  it "sem perfil, usa o nome do catálogo" do
    expect(described_class.body(TEST_CITY_A))
      .to eq("Secretaria de Saúde de #{TEST_CITY_A.name}: você tem um aviso novo. Acesse #{link}")
  end

  describe Campaigns::SmsSetting do
    it "desligada sem perfil e por padrão; ligada quando o perfil liga" do
      expect(described_class.enabled?).to be(false)
      profile = CityProfile.create!(name: "Curitiba")
      expect(described_class.enabled?).to be(false)
      profile.update!(campaigns_sms_enabled: true)
      expect(described_class.enabled?).to be(true)
    end
  end
end
