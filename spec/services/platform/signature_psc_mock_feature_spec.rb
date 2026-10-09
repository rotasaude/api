require "rails_helper"

# ADR 0032 (revisão): signature_psc_mock só existe fora de produção.
RSpec.describe "Interruptor signature_psc_mock" do
  let(:city) { clinical_city! }

  def set(key, enabled, **opts)
    Platform::Features.set!(city: city, key: key, enabled: enabled, maintainer: ledi_maintainer!, **opts)
  end

  it "exige digital_signature utilizável (digital_signature_disabled)" do
    set("signature_psc_mock", true)
    expect(Platform::Features.missing(city, "signature_psc_mock")).to eq([ "digital_signature_disabled" ])
    expect(Signatures::PscMock.on?(city)).to be(false)

    set("digital_signature", true)
    expect(Platform::Features.missing(city, "signature_psc_mock")).to eq([])
    expect(Signatures::PscMock.on?(city)).to be(true)

    set("clinical_record", false) # derruba a cadeia
    expect(Signatures::PscMock.on?(city)).to be(false)
  end

  it "existe em development, test e staging" do
    %w[development test staging].each do |env|
      expect(Platform::Features.catalog(env: env).map(&:key)).to include("signature_psc_mock")
      expect(Platform::Features.find("signature_psc_mock", env: env)).not_to be_nil
    end
  end

  describe "em produção" do
    it "o catálogo e o resumo nunca o oferecem" do
      expect(Platform::Features.catalog(env: "production").map(&:key)).not_to include("signature_psc_mock")
      keys = Platform::Features.summary(city, env: "production").map { |r| r[:key] }
      expect(keys).to include("digital_signature")
      expect(keys).not_to include("signature_psc_mock")
    end

    it "find devolve nil (a mutation do maintenance responde unknown_feature)" do
      expect(Platform::Features.find("signature_psc_mock", env: "production")).to be_nil
    end

    it "set! recusa e não escreve nada" do
      city # materializa a cidade (clinical_city! liga o prontuário) antes de contar
      ledi_maintainer!
      expect do
        expect { set("signature_psc_mock", true, env: "production") }.to raise_error(Platform::Features::UnknownFeature)
      end.not_to change(CityFeature, :count)
    end

    it "não é utilizável nem com linha existente" do
      set("digital_signature", true)
      CityFeature.create!(city_id: city.id, key: "signature_psc_mock", enabled: true,
                          changed_by_maintainer: ledi_maintainer!, changed_at: Time.current)
      expect(Platform::Features.usable?(city, "signature_psc_mock")).to be(true)
      expect(Platform::Features.usable?(city, "signature_psc_mock", env: "production")).to be(false)
      expect(Signatures::PscMock.on?(city, env: "production")).to be(false)
      expect(Platform::Features.enabled_keys(city, env: "production")).not_to include("signature_psc_mock")
    end
  end
end
