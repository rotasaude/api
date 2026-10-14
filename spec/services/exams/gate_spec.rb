require "rails_helper"

# ADR 0036 (contrato §11; Desvio 1 / Divergência D1): exam_tracking exige só
# record_mode (record ou integrated); os outros três em cadeia; fake_lab
# nunca em produção.
RSpec.describe Exams::Gate do
  def set(city, key, enabled = true)
    Platform::Features.set!(city: city, key: key, enabled: enabled, maintainer: ledi_maintainer!)
  end

  it "exam_tracking vale em record e integrated, nunca em off" do
    city = clinical_city!(record_mode: "off", enabled: false)
    set(city, "exam_tracking")
    expect(Platform::Features.missing(city, "exam_tracking")).to eq(%w[record_mode_off])
    expect(described_class.usable?(city)).to be(false)
    city.update!(record_mode: "integrated")
    expect(described_class.usable?(city)).to be(true)
    city.update!(record_mode: "record")
    expect(described_class.usable?(city)).to be(true)
    expect(described_class.usable?(nil)).to be(false)
  end

  it "a cadeia: fhir exige exam_tracking; fake_lab exige fhir; pec exige exam_tracking e pec_external_view" do
    city = clinical_city!(record_mode: "integrated", enabled: false)
    %w[exam_fhir_inbound fake_lab exam_pec_bridge].each { |key| set(city, key) }
    expect(Platform::Features.missing(city, "exam_fhir_inbound")).to eq(%w[exam_tracking_disabled])
    expect(Platform::Features.missing(city, "fake_lab")).to eq(%w[exam_fhir_inbound_disabled])
    expect(Platform::Features.missing(city, "exam_pec_bridge")).to eq(%w[exam_tracking_disabled pec_external_view_disabled])
    set(city, "exam_tracking")
    expect(described_class.fhir_usable?(city)).to be(true)
    expect(described_class.fake_lab_usable?(city)).to be(true)
    expect(Platform::Features.missing(city, "exam_pec_bridge")).to eq(%w[pec_external_view_disabled])
    expect(described_class.pec_usable?(city)).to be(false)
  end

  it "fake_lab não existe em produção (nem no catálogo, nem para ligar)" do
    expect(Platform::Features.catalog(env: "production").map(&:key)).not_to include("fake_lab")
    expect(Platform::Features.catalog(env: "production").map(&:key)).to include("exam_tracking", "exam_fhir_inbound", "exam_pec_bridge")
    city = clinical_city!
    expect { Platform::Features.set!(city: city, key: "fake_lab", enabled: true, maintainer: ledi_maintainer!, env: "production") }
      .to raise_error(Platform::Features::UnknownFeature)
    expect(described_class.fake_lab_usable?(city, env: "production")).to be(false)
  end
end
