require "rails_helper"

# Módulo 26c (Valor 1; Q10): o interruptor do envio da regulação à RNDS.
# O estado da cidade é simulado nos casos de borda; o caminho real (credencial
# gravada, CHECK de `kind` da Task 5) tem o seu exemplo.
RSpec.describe Regulation::RndsGate, type: :model do
  let(:city) { clinical_city! }

  def stub_state(credentials: {}, ibge_code: "4106902", uf: "PR")
    allow(Platform::Features).to receive(:city_state).with(city)
      .and_return({ credentials: credentials, ibge_code: ibge_code, uf: uf, pec_origin: false, pec_hmac_key: false })
  end

  def enable!
    Platform::Features.set!(city: city, key: "care_regulation", enabled: true, maintainer: ledi_maintainer!)
    Platform::Features.set!(city: city, key: "rnds_regulation", enabled: true, maintainer: ledi_maintainer!)
  end

  it "KEY é rnds_regulation" do
    expect(described_class::KEY).to eq("rnds_regulation")
  end

  it "usable? é falso sem credencial e verdadeiro com credencial ok, IBGE e UF" do
    enable!
    stub_state
    expect(described_class.usable?(city)).to be(false)
    stub_state(credentials: { "rnds_regulation" => "unauthorized" })
    expect(described_class.usable?(city)).to be(false)
    stub_state(credentials: { "rnds_regulation" => "ok" })
    expect(described_class.usable?(city)).to be(true)
    stub_state(credentials: { "rnds_regulation" => "ok" }, uf: nil)
    expect(described_class.usable?(city)).to be(false)
  end

  it "enabled? só lê o interruptor" do
    expect(described_class.enabled?(city)).to be(false)
    enable!
    stub_state
    expect(described_class.enabled?(city)).to be(true)
    expect(described_class.usable?(city)).to be(false)
  end

  it "com a credencial gravada de verdade: sem ela não passa; gravada passa; recusada na conferência não passa" do
    enable!
    CityConnection.with(city) { city_profile!.update!(uf: "PR", ibge_code: "4106902") }
    expect(described_class.usable?(city)).to be(false)
    CityConnection.with(city) { rnds_regulation_credential! }
    expect(described_class.usable?(city)).to be(true)
    CityConnection.with(city) { IntegrationCredential.find_by!(kind: "rnds_regulation").update_columns(last_check_status: "unauthorized") }
    expect(described_class.usable?(city)).to be(false)
  end

  it "cidade nula não passa" do
    expect(described_class.usable?(nil)).to be(false)
    expect(described_class.enabled?(nil)).to be(false)
  end
end
