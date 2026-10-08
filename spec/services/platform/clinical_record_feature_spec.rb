require "rails_helper"

# ADR 0031 (spec §4, §10): o prontuário fica atrás do interruptor
# clinical_record, que só é utilizável no modo record. O maintenance liga pelo
# mecanismo genérico (catálogo), sem código novo.
RSpec.describe "Interruptor clinical_record" do
  let(:city) { register_test_city! }

  def set(enabled) = Platform::Features.set!(city: city, key: "clinical_record", enabled: enabled, maintainer: ledi_maintainer!)

  it "está no catálogo e exige record_mode = record" do
    expect(Platform::Features::KEYS).to include("clinical_record")
    set(true)
    { "off" => [ "record_mode_not_record" ], "integrated" => [ "record_mode_not_record" ], "record" => [] }.each do |mode, missing|
      city.update!(record_mode: mode)
      expect(Platform::Features.missing(city, "clinical_record")).to eq(missing), mode
      expect(ClinicalRecord::Gate.usable?(city)).to eq(missing.empty?), mode
    end
  end

  it "desligado não é utilizável; sem cidade também não" do
    city.update!(record_mode: "record")
    expect(ClinicalRecord::Gate.usable?(city)).to be(false)
    expect(ClinicalRecord::Gate.usable?(nil)).to be(false)
    expect(ClinicalRecord::Gate.usable?(TEST_CITY_A)).to be(false) # sem linha na plataforma
  end

  it "o resumo do maintenance mostra o interruptor e o que falta" do
    set(true)
    row = Platform::Features.summary(city).find { |r| r[:key] == "clinical_record" }
    expect(row).to include(enabled: true, usable: false, missing: [ "record_mode_not_record" ])
  end
end
