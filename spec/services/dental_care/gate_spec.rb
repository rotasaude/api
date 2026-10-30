require "rails_helper"

# Módulo 28 (ADR 0046): o interruptor dental_care exige o prontuário.
RSpec.describe DentalCare::Gate do
  it "está no catálogo depois de pharmacy, exigindo o prontuário" do
    expect(Platform::Features.find("dental_care").requires).to eq(%w[feature:clinical_record])
    keys = Platform::Features::KEYS
    expect(keys.index("dental_care")).to eq(keys.index("pharmacy") + 1)
    expect(described_class::KEY).to eq("dental_care")
  end

  it "sem a linha da cidade: falso nos dois" do
    city = clinical_city!(record_mode: "record", enabled: false)
    expect(described_class.usable?(city)).to be(false)
    expect(described_class.enabled?(city)).to be(false)
  end

  it "dental_care ligado com o prontuário desligado: enabled? sim, usable? não" do
    city = clinical_city!(record_mode: "integrated", enabled: false)
    Platform::Features.set!(city: city, key: "dental_care", enabled: true, maintainer: ledi_maintainer!)
    expect(described_class.enabled?(city)).to be(true)
    expect(described_class.usable?(city)).to be(false)
  end

  it "os dois ligados: usable? e enabled?" do
    city = clinical_city!
    Platform::Features.set!(city: city, key: "dental_care", enabled: true, maintainer: ledi_maintainer!)
    expect(described_class.usable?(city)).to be(true)
    expect(described_class.enabled?(city)).to be(true)
  end

  it "cidade nula ou sem id: falso, sem exceção" do
    expect(described_class.usable?(nil)).to be(false)
    expect(described_class.enabled?(City.new)).to be(false)
  end

  it "o catálogo traz as faixas fixadas" do
    catalog = DentalCare::Catalog
    expect(catalog::RECESSION_MM).to eq(-10..20)
    expect(catalog::LAB_NAME).to eq(3..120)
    expect(catalog::PERMANENT_TEETH.size).to eq(32)
    expect(catalog::DECIDUOUS_TEETH.size).to eq(20)
    expect(catalog::OUTCOMES).to include(15, 17)
  end
end
