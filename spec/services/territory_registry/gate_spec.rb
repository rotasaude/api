require "rails_helper"

# Módulo 24a (ADR 0042): territory_registry exige o prontuário utilizável (modo record).
RSpec.describe TerritoryRegistry::Gate do
  it "está no catálogo depois de care_lines e exige o prontuário utilizável" do
    entry = Platform::Features::CATALOG.find { |e| e.key == "territory_registry" }
    expect(entry.requires).to eq(%w[feature:clinical_record ibge_code uf])
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

  # Contrato §14 L20: o mesmo mecanismo do procedure_billing — o requires
  # ibge_code/uf aparece no maintenance (missing, usable false); as rotas
  # seguem só com o prontuário utilizável e a ficha vira "não gerada".
  it "UF e IBGE da cidade: o maintenance vê o que falta; as rotas não dependem deles" do
    city = clinical_city!
    Platform::Features.set!(city: city, key: "territory_registry", enabled: true, maintainer: ledi_maintainer!)
    profile = CityConnection.with(city) { CityProfile.current || CityProfile.create!(name: city.name) }
    CityConnection.with(city) { profile.update!(uf: nil, ibge_code: nil) }
    expect(Platform::Features.missing(city, "territory_registry")).to eq(%w[ibge_code_missing uf_missing])
    row = Platform::Features.summary(city).find { |feature| feature[:key] == "territory_registry" }
    expect(row).to include(enabled: true, usable: false, missing: %w[ibge_code_missing uf_missing])
    expect(described_class.usable?(city)).to be(true)
    CityConnection.with(city) { profile.update!(ibge_code: "4106902") }
    expect(Platform::Features.missing(city, "territory_registry")).to eq(%w[uf_missing])
    CityConnection.with(city) { profile.update!(uf: "PR") }
    expect(Platform::Features.missing(city, "territory_registry")).to eq([])
    city.update!(record_mode: "off")
    expect(described_class.usable?(city)).to be(false)
  end
end
