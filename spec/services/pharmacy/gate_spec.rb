require "rails_helper"

# Módulo 27a (ADR 0045): o interruptor pharmacy, sem pré-requisito.
RSpec.describe Pharmacy::Gate do
  it "está no catálogo depois de care_regulation, sem pré-requisito" do
    entry = Platform::Features.find("pharmacy")
    expect(entry.requires).to eq([])
    keys = Platform::Features::KEYS
    expect(keys.index("pharmacy")).to eq(keys.index("care_regulation") + 1)
    expect(described_class::KEY).to eq("pharmacy")
  end

  it "sem a linha da cidade: falso" do
    city = clinical_city!(enabled: false)
    expect(described_class.usable?(city)).to be(false)
  end

  it "ligado: verdadeiro, mesmo com o prontuário desligado" do
    city = clinical_city!(record_mode: "integrated", enabled: false)
    Platform::Features.set!(city: city, key: "pharmacy", enabled: true, maintainer: ledi_maintainer!)
    expect(described_class.usable?(city)).to be(true)
  end

  it "desligado depois de ligado: falso" do
    city = clinical_city!
    Platform::Features.set!(city: city, key: "pharmacy", enabled: true, maintainer: ledi_maintainer!)
    Platform::Features.set!(city: city, key: "pharmacy", enabled: false, maintainer: ledi_maintainer!)
    expect(described_class.usable?(city)).to be(false)
  end

  it "cidade nula ou sem id: falso, sem exceção" do
    expect(described_class.usable?(nil)).to be(false)
    expect(described_class.usable?(City.new)).to be(false)
  end
end
