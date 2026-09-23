require "rails_helper"

RSpec.describe OtpSender do
  after { described_class::Test.reset! }

  it "em teste, guarda o envio em memória" do
    described_class.deliver(phone: "+5541998765432", code: "123456")
    expect(described_class::Test.deliveries).to eq([{ phone: "+5541998765432", code: "123456" }])
  end

  it "sem provedor configurado, levanta Unavailable" do
    original = Rails.configuration.x.otp_sender
    Rails.configuration.x.otp_sender = nil
    begin
      expect { described_class.deliver(phone: "+5541998765432", code: "123456") }
        .to raise_error(OtpSender::Unavailable)
    ensure
      Rails.configuration.x.otp_sender = original
    end
  end

  it "o de log mostra o telefone mascarado" do
    original = Rails.configuration.x.otp_sender
    Rails.configuration.x.otp_sender = :log
    begin
      expect(Rails.logger).to receive(:info).with("[otp] (**) *****-5432 code=123456")
      described_class.deliver(phone: "+5541998765432", code: "123456")
    ensure
      Rails.configuration.x.otp_sender = original
    end
  end
end
