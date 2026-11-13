require "rails_helper"

RSpec.describe Professionals::Cbo do
  it "toda entrada tem código de 6 dígitos único, título e conselho conhecido ou nulo" do
    codes = described_class.all.map(&:code)
    expect(codes).to all(match(/\A\d{6}\z/))
    expect(codes.uniq.size).to eq(codes.size)
    expect(described_class.all.map(&:title)).to all(be_present)
    expect(described_class.all.map(&:council).compact - Professional::COUNCILS).to be_empty
  end

  it "acha pelo código, com o conselho esperado" do
    expect(described_class.find("225125")).to have_attributes(title: "Médico clínico", council: "CRM")
    expect(described_class.find("999999")).to be_nil
  end

  it "só os profissionais de campo (Tabela 7 do LEDI: ACS, endemias e os do 24b) não exigem conselho (módulos 24a e 24b)" do
    expect(described_class.all.reject(&:council).map(&:code))
      .to contain_exactly("515105", "515140", "322255", "515310", "515125", "515130", "515120")
  end

  # Módulo 24b (ADR 0052; §16 Q48): todo CBO que registra visita (Tabela 7,
  # config/ledi/registration_cbos.yml) abre vínculo com a unidade.
  it "a Tabela 7 do LEDI está toda no catálogo da plataforma" do
    expect(TerritoryRegistry::Access::REGISTRATION_CBOS.fetch(:home_visit).to_a - described_class.all.map(&:code)).to be_empty
  end

  it "active deixa de fora os deprecated" do
    expect(described_class.active).to all(have_attributes(deprecated: false))
  end
end
