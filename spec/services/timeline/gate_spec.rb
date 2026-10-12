require "rails_helper"

# ADR 0035 (spec §3; contrato §6): patient_timeline sem pré-requisito;
# pec_external_view exige patient_timeline e o modo integrado.
RSpec.describe Timeline::Gate do
  def set(city, key, enabled)
    Platform::Features.set!(city: city, key: key, enabled: enabled, maintainer: ledi_maintainer!)
  end

  it "patient_timeline liga sozinho, em qualquer modo" do
    city = clinical_city!(record_mode: "off", enabled: false)
    expect(described_class.enabled?(city)).to be(false)
    set(city, "patient_timeline", true)
    expect(Platform::Features.missing(city, "patient_timeline")).to eq([])
    expect(described_class.enabled?(city)).to be(true)
    expect(described_class.enabled?(nil)).to be(false)
  end

  it "pec_external_view exige patient_timeline, record_mode integrated e a configuração do PEC" do
    city = clinical_city!(record_mode: "record", enabled: false)
    set(city, "pec_external_view", true)
    expect(Platform::Features.missing(city, "pec_external_view"))
      .to eq(%w[patient_timeline_disabled record_mode_not_integrated pec_origin_missing pec_hmac_key_missing])
    expect(described_class.pec_usable?(city)).to be(false)

    set(city, "patient_timeline", true)
    city.update!(record_mode: "integrated")
    # Sem linha em pec_settings, a origem e a chave contam como ausentes.
    expect(Platform::Features.missing(city, "pec_external_view")).to eq(%w[pec_origin_missing pec_hmac_key_missing])
    expect(described_class.pec_usable?(city)).to be(false)
    expect(described_class.pec_usable?(nil)).to be(false)
  end

  it "partial? é verdadeiro fora do modo record" do
    expect(described_class.partial?(clinical_city!(record_mode: "integrated", enabled: false))).to be(true)
    expect(described_class.partial?(clinical_city!(record_mode: "record"))).to be(false)
  end
end
