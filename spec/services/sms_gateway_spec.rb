require "rails_helper"

RSpec.describe SmsGateway do
  it "test (backend da suíte): guarda a entrega e está configurado" do
    described_class.deliver(phone: "+5541998765432", body: "Aviso")
    expect(SmsGateway::Test.deliveries).to eq([ { phone: "+5541998765432", body: "Aviso" } ])
    expect(described_class.configured?).to be(true)
  end

  it "log (development): telefone mascarado e o texto, nunca o número inteiro" do
    with_sms_gateway(:log) do
      logged = []
      allow(Rails.logger).to receive(:info) { |message| logged << message }
      described_class.deliver(phone: "+5541998765432", body: "Aviso")
      expect(logged).to eq([ "[sms] (**) *****-5432 Aviso" ])
      expect(described_class.configured?).to be(true)
    end
  end

  it "sem backend (production): não configurado e deliver levanta Unavailable" do
    with_sms_gateway(nil) do
      expect(described_class.configured?).to be(false)
      expect { described_class.deliver(phone: "+5541998765432", body: "Aviso") }
        .to raise_error(SmsGateway::Unavailable)
    end
  end
end
