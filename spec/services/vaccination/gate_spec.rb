require "rails_helper"

RSpec.describe Vaccination::Gate do
  it "vaccination exige record_mode record; rnds_immunization exige vaccination e credencial; rnds_mock só fora de produção" do
    city = clinical_city!(record_mode: "integrated")
    Platform::Features.set!(city: city, key: "vaccination", enabled: true, maintainer: ledi_maintainer!)
    expect(Platform::Features.missing(city, "vaccination")).to eq([ "record_mode_not_record" ])
    city.update!(record_mode: "record")
    expect(described_class.usable?(city)).to be(true)
    Platform::Features.set!(city: city, key: "rnds_immunization", enabled: true, maintainer: ledi_maintainer!)
    expect(Platform::Features.missing(city, "rnds_immunization")).to eq([ "credential_missing:rnds" ])
    expect(Platform::Features.find("rnds_mock", env: "production")).to be_nil
  end

  it "em produção o catálogo em revisão bloqueia o envio" do
    city = vaccination_city!(rnds: true)
    allow(Vaccination::Catalog).to receive(:under_review?).and_return(true)
    expect(Platform::Features.missing(city, "rnds_immunization", env: "production")).to include("vaccination_catalog_under_review")
    expect(Platform::Features.missing(city, "rnds_immunization", env: "test")).to eq([])
  end

  it "vaccination_city!(rnds: true) deixa envio e simulado utilizáveis" do
    city = vaccination_city!(rnds: true)
    expect(Rnds::Gate.usable?(city)).to be(true)
    expect(Rnds::Mock.on?(city, env: "test")).to be(true)
    expect(Rnds::Mock.on?(city, env: "production")).to be(false)
  end
end
