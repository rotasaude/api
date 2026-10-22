require "rails_helper"

# ADR 0040 (spec §3): care_lines exige clinical_record utilizável (modo record).
RSpec.describe CareLines::Gate do
  it "está no catálogo depois de procedure_billing, com o pré-requisito do prontuário" do
    entry = Platform::Features.find!("care_lines")
    expect(entry.requires).to eq(%w[feature:clinical_record])
    expect(Platform::Features::KEYS.last(2)).to eq(%w[procedure_billing care_lines])
  end

  it "usable? só com clinical_record utilizável; enabled? só olha a chave" do
    city = clinical_city!(record_mode: "integrated", enabled: true)
    Platform::Features.set!(city: city, key: "care_lines", enabled: true, maintainer: ledi_maintainer!)
    expect(described_class.enabled?(city)).to be(true)
    expect(described_class.usable?(city)).to be(false)
    expect(Platform::Features.missing(city, "care_lines")).to eq(%w[clinical_record_disabled])

    city.update!(record_mode: "record")
    CityCatalog.reset_cache!
    expect(described_class.usable?(city)).to be(true)
  end

  it "cidade nula ou sem id: falso, sem exceção" do
    expect(described_class.usable?(nil)).to be(false)
    expect(described_class.enabled?(City.new)).to be(false)
  end
end
