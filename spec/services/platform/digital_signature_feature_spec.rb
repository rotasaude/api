require "rails_helper"

# ADR 0032 (spec §3): assinatura digital atrás do interruptor
# digital_signature, que só é utilizável com o prontuário (clinical_record)
# utilizável. O maintenance liga pelo mecanismo genérico (catálogo).
RSpec.describe "Interruptor digital_signature" do
  let(:city) { clinical_city! }

  def set(key, enabled) = Platform::Features.set!(city: city, key: key, enabled: enabled, maintainer: ledi_maintainer!)

  it "está no catálogo e exige o prontuário utilizável" do
    expect(Platform::Features::KEYS).to include("digital_signature")
    set("digital_signature", true)
    expect(Platform::Features.missing(city, "digital_signature")).to eq([])
    expect(Signatures::Gate.usable?(city)).to be(true)

    set("clinical_record", false)
    expect(Platform::Features.missing(city, "digital_signature")).to eq([ "clinical_record_disabled" ])
    expect(Signatures::Gate.usable?(city)).to be(false)

    set("clinical_record", true)
    city.update!(record_mode: "integrated")
    expect(Platform::Features.missing(city, "digital_signature")).to eq([ "clinical_record_disabled" ])
    expect(Signatures::Gate.usable?(city)).to be(false)
  end

  it "desligado não é utilizável; sem cidade também não" do
    expect(Signatures::Gate.usable?(city)).to be(false)
    expect(Signatures::Gate.usable?(nil)).to be(false)
  end

  it "o resumo do maintenance mostra o interruptor e o que falta" do
    set("digital_signature", true)
    set("clinical_record", false)
    row = Platform::Features.summary(city).find { |r| r[:key] == "digital_signature" }
    expect(row).to include(enabled: true, usable: false, missing: [ "clinical_record_disabled" ])
  end

  it "pré-requisito desconhecido continua levantando" do
    expect { Platform::Features.missing_for("feature-sem-dois-pontos", {}, {}, city: city) }.to raise_error(ArgumentError)
  end
end
