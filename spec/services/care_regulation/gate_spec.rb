require "rails_helper"

# Módulo 26a (ADR 0044): o interruptor care_regulation exige o prontuário.
RSpec.describe CareRegulation::Gate do
  it "está no catálogo depois de surveillance, exigindo o prontuário" do
    entry = Platform::Features.find("care_regulation")
    expect(entry.requires).to eq(%w[feature:clinical_record])
    keys = Platform::Features::KEYS
    expect(keys.index("care_regulation")).to eq(keys.index("surveillance") + 1)
  end

  it "sem a linha da cidade: falso nos dois" do
    city = clinical_city!(record_mode: "record", enabled: false)
    expect(described_class.usable?(city)).to be(false)
    expect(described_class.enabled?(city)).to be(false)
  end

  it "ligado com o prontuário desligado: enabled? sim, usable? não" do
    city = clinical_city!(record_mode: "integrated", enabled: false)
    Platform::Features.set!(city: city, key: "care_regulation", enabled: true, maintainer: ledi_maintainer!)
    expect(described_class.enabled?(city)).to be(true)
    expect(described_class.usable?(city)).to be(false)
  end

  it "os dois ligados: usable? e enabled?" do
    city = clinical_city!
    Platform::Features.set!(city: city, key: "care_regulation", enabled: true, maintainer: ledi_maintainer!)
    expect(described_class.usable?(city)).to be(true)
    expect(described_class.enabled?(city)).to be(true)
  end

  it "cidade nula ou sem id: falso, sem exceção" do
    expect(described_class.usable?(nil)).to be(false)
    expect(described_class.enabled?(City.new)).to be(false)
  end
end
