require "rails_helper"

# ADR 0034 (spec §3; contrato §8): controlled_prescriptions exige
# clinical_documents utilizável; sncr_mock exige controlled_prescriptions e
# só existe fora de produção (como o signature_psc_mock do 19b).
RSpec.describe "Interruptores do 19d" do
  let(:city) { clinical_city! }

  def set(key, enabled, env: Rails.env)
    Platform::Features.set!(city: city, key: key, enabled: enabled, maintainer: ledi_maintainer!, env: env)
  end

  it "controlled_prescriptions exige os documentos clínicos utilizáveis" do
    set("controlled_prescriptions", true)
    expect(Platform::Features.missing(city, "controlled_prescriptions")).to eq([ "clinical_documents_disabled" ])
    expect(ControlledPrescriptions::Gate.usable?(city)).to be(false)

    set("clinical_documents", true)
    expect(Platform::Features.missing(city, "controlled_prescriptions")).to eq([])
    expect(ControlledPrescriptions::Gate.usable?(city)).to be(true)
    expect(ControlledPrescriptions::Gate.usable?(nil)).to be(false)
  end

  it "sncr_mock exige controlled_prescriptions e não depende da assinatura" do
    set("clinical_documents", true)
    set("sncr_mock", true)
    expect(Platform::Features.missing(city, "sncr_mock")).to eq([ "controlled_prescriptions_disabled" ])
    expect(Sncr::Mock.on?(city)).to be(false)

    set("controlled_prescriptions", true)
    expect(Sncr::Mock.on?(city)).to be(true)
    expect(Platform::Features.enabled?(city, "digital_signature")).to be(false)
  end

  it "sncr_mock não existe em produção: fora do catálogo, recusa ligar, linha órfã não vale" do
    set("clinical_documents", true)
    set("controlled_prescriptions", true)
    set("sncr_mock", true)
    expect(Platform::Features.catalog(env: "production").map(&:key)).to include("controlled_prescriptions")
    expect(Platform::Features.catalog(env: "production").map(&:key)).not_to include("sncr_mock")
    expect { set("sncr_mock", true, env: "production") }.to raise_error(Platform::Features::UnknownFeature)
    expect(Sncr::Mock.on?(city, env: "production")).to be(false)
    expect(Sncr::Mock.on?(nil)).to be(false)
  end
end
