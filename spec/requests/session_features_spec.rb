require "rails_helper"

# Contratos §1 (session-v1.1.0): a sessão da cidade traz as chaves LIGADAS —
# não necessariamente utilizáveis —, únicas; o console não.
RSpec.describe "features na sessão", type: :request do
  let(:city) { City.find_by!(slug: TEST_CITY_A.slug) }
  let(:maintainer) do
    Maintainer.create!(email_address: "sf-#{SecureRandom.hex(3)}@rotasaude.app", password: "s3nha-forte-1",
                       otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
  end
  def json = JSON.parse(response.body)

  it "sem interruptor ligado: lista vazia" do
    sign_in_as(staff_with("admin@cidade.gov.br", "municipal_admin"))
    get "/session"
    expect(json["features"]).to eq([])
  end

  it "ligado aparece mesmo sem credencial; desligado não" do
    Platform::Features.set!(city: city, key: "cadsus_lookup", enabled: true, maintainer: maintainer)
    Platform::Features.set!(city: city, key: "ledi_export", enabled: false, maintainer: maintainer)
    sign_in_as(staff_with("admin@cidade.gov.br", "municipal_admin"))
    get "/session"
    expect(json["features"]).to eq(%w[cadsus_lookup])
    expect(json["features"]).to all(match(/\A[a-z][a-z0-9_]*\z/))
  end

  it "operador vindo do console também recebe" do
    Platform::Features.set!(city: city, key: "ledi_export", enabled: true, maintainer: maintainer)
    operator = Operator.create!(email_address: "op-#{SecureRandom.hex(3)}@rotasaude.app", password: "s3nha-forte-1",
                                otp_secret: ROTP::Base32.random, otp_enabled: true)
    sign_in_operator_grant(operator)
    get "/session"
    expect(json["features"]).to eq(%w[ledi_export])
  end
end
