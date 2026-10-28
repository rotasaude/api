require "rails_helper"

# Módulo 25 (ADR 0043): o interruptor surveillance, sem pré-requisito.
RSpec.describe Surveillance::Gate do
  it "está no catálogo depois de territory_registry, sem pré-requisito" do
    entry = Platform::Features::CATALOG.find { |e| e.key == "surveillance" }
    expect(entry.requires).to eq([])
    keys = Platform::Features::KEYS
    expect(keys.index("surveillance")).to eq(keys.index("territory_registry") + 1)
  end

  it "usable? com o interruptor; consultation_usable? exige também o prontuário" do
    city = clinical_city!(record_mode: "integrated", enabled: false)
    expect(described_class.usable?(city)).to be(false)
    Platform::Features.set!(city: city, key: "surveillance", enabled: true, maintainer: ledi_maintainer!)
    expect(described_class.usable?(city)).to be(true)
    expect(described_class.consultation_usable?(city)).to be(false)
    clinical_city!
    expect(described_class.consultation_usable?(city.reload)).to be(true)
    expect(described_class.usable?(nil)).to be(false)
  end

  it "cidade nula ou sem id: falso, sem exceção; enabled? só olha a chave" do
    expect(described_class.usable?(City.new)).to be(false)
    expect(described_class.enabled?(nil)).to be(false)
    expect(described_class.enabled?(City.new)).to be(false)
    expect(described_class.consultation_usable?(nil)).to be(false)
    city = clinical_city!
    Platform::Features.set!(city: city, key: "surveillance", enabled: true, maintainer: ledi_maintainer!)
    expect(described_class.enabled?(city)).to be(true)
  end
end
