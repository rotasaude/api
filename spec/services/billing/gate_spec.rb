require "rails_helper"

# ADR 0039 (contrato §1 e §8, com M1/M2 do maintenance): procedure_billing
# sem pré-requisito de modo (vale no integrado), exige só o IBGE da cidade
# (vai no BPA-I), existe em todos os ambientes; o portão lê só a plataforma.
RSpec.describe Billing::Gate do
  it "liga no modo integrado; utilizável só com o IBGE da cidade" do
    city = clinical_city!(record_mode: "integrated", enabled: false)
    expect(described_class.enabled?(city)).to be(false)
    Platform::Features.set!(city: city, key: "procedure_billing", enabled: true, maintainer: ledi_maintainer!)
    expect(described_class.enabled?(city)).to be(true)
    expect(Platform::Features.missing(city, "procedure_billing")).to eq([ "ibge_code_missing" ])
    city_profile!
    expect(Platform::Features.missing(city, "procedure_billing")).to eq([])
    entry = Platform::Features.find("procedure_billing", env: "production")
    expect(entry).to have_attributes(requires: %w[ibge_code], environments: nil)
  end

  it "sem cidade, desligado" do
    expect(described_class.enabled?(nil)).to be(false)
    expect(described_class.enabled?(City.new)).to be(false)
  end
end
