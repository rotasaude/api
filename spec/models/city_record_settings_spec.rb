require "rails_helper"

# ADR 0028 (spec 2026-10-05 §3): modo de prontuário e endereço do PEC na
# plataforma; interruptores por cidade, um por chave do catálogo.
RSpec.describe "Modo de prontuário e interruptores da cidade" do
  let(:city) { create(:city) }
  let(:maintainer) do
    Maintainer.create!(email_address: "m-#{SecureRandom.hex(3)}@rotasaude.app", password: "s3nha-forte-1",
                       otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
  end

  it "nasce off e sem PEC" do
    expect(city.record_mode).to eq("off")
    expect(city.pec_url).to be_nil
  end

  it "recusa modo fora da lista, no modelo e no banco" do
    city.record_mode = "parcial"
    expect(city).not_to be_valid
    expect { City.where(id: city.id).update_all(record_mode: "parcial") }.to raise_error(ActiveRecord::StatementInvalid)
  end

  it "aceita só https sem credencial, query ou fragmento" do
    ok = %w[https://pec.cidade.gov.br https://pec.cidade.gov.br:8443/esus]
    bad = [ "http://pec.cidade.gov.br", "https://admin:senha@pec.cidade.gov.br", "https://pec.cidade.gov.br/?a=1",
            "https://pec.cidade.gov.br/#x", "https://", "pec.cidade.gov.br", " ", "https://#{'a' * 250}.br" ]
    ok.each { |url| expect(City.valid_pec_url?(url)).to be(true), url }
    bad.each { |url| expect(City.valid_pec_url?(url)).to be(false), url }
    city.pec_url = "http://pec.cidade.gov.br"
    expect(city).not_to be_valid
    expect { City.where(id: city.id).update_all(pec_url: "http://x") }.to raise_error(ActiveRecord::StatementInvalid)
  end

  it "um interruptor por cidade e chave; chave fora do catálogo é inválida" do
    CityFeature.create!(city: city, key: "cadsus_lookup", enabled: true, changed_by_maintainer: maintainer,
                        changed_at: Time.current)
    expect {
      CityFeature.new(city: city, key: "cadsus_lookup", changed_by_maintainer: maintainer, changed_at: Time.current)
                 .save!(validate: false)
    }.to raise_error(ActiveRecord::RecordNotUnique)
    expect(CityFeature.new(city: city, key: "rnds", changed_by_maintainer: maintainer, changed_at: Time.current))
      .not_to be_valid
  end

  it "catálogo em código, com as duas chaves" do
    expect(Platform::Features::KEYS).to eq(%w[ledi_export cadsus_lookup])
    expect(Platform::Features.find("cadsus_lookup").requires).to eq(%w[credential:cadsus])
    expect(Platform::Features.find("nada")).to be_nil
  end
end
