require "rails_helper"

# Módulo 24a (ADR 0042): territory_registry exige o prontuário utilizável (modo record).
RSpec.describe TerritoryRegistry::Gate do
  it "está no catálogo depois de care_lines e exige o prontuário utilizável" do
    entry = Platform::Features::CATALOG.find { |e| e.key == "territory_registry" }
    expect(entry.requires).to eq(%w[feature:clinical_record])
    expect(Platform::Features::KEYS.last(2)).to eq(%w[care_lines territory_registry])
  end

  it "usable? só com o interruptor ligado e o modo record; enabled? só o interruptor" do
    city = clinical_city!
    expect(described_class.usable?(city)).to be(false)
    Platform::Features.set!(city: city, key: "territory_registry", enabled: true, maintainer: ledi_maintainer!)
    expect(described_class.usable?(city)).to be(true)
    city.update!(record_mode: "off")
    expect(described_class.usable?(city)).to be(false)
    expect(described_class.enabled?(city)).to be(true)
    expect(described_class.usable?(nil)).to be(false)
  end

  it "cidade nula ou sem id: falso, sem exceção" do
    expect(described_class.usable?(City.new)).to be(false)
    expect(described_class.enabled?(nil)).to be(false)
    expect(described_class.enabled?(City.new)).to be(false)
  end
end
