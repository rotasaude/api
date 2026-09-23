# Entrega do código de confirmação (spec 2026-09-22-web-citizen-channel §2.5).
# Um provedor só, da plataforma, escolhido por `config.x.otp_sender`. O
# provedor real de SMS é pendência de go-live (spec §7): sem ele, o envio
# levanta Unavailable e a API responde 503.
module OtpSender
  class Unavailable < StandardError; end

  def self.deliver(phone:, code:)
    backend.deliver(phone: phone, code: code)
  end

  def self.backend
    case Rails.configuration.x.otp_sender
    when :log  then Log
    when :test then Test
    else Unconfigured
    end
  end

  # Desenvolvimento: o código aparece no log do api.
  module Log
    def self.deliver(phone:, code:)
      Rails.logger.info("[otp] #{CitizenIdentity::Phone.mask(phone)} code=#{code}")
    end
  end

  module Test
    def self.deliveries
      @deliveries ||= []
    end

    def self.deliver(phone:, code:)
      deliveries << { phone: phone, code: code }
    end

    def self.reset!
      deliveries.clear
    end
  end

  module Unconfigured
    def self.deliver(**)
      raise Unavailable, "no SMS provider configured"
    end
  end
end
