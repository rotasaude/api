# Envio de SMS das campanhas (ADR 0024; spec 2026-09-29 §5.5). O backend vem de
# `config.x.sms_gateway`: :log (development), :test (test); ausente (production
# e staging) → Unconfigured, e o deploy não envia SMS. O provedor real é um
# backend novo, escolhido no go-live. O OtpSender segue separado; os dois se
# unificam quando o provedor for escolhido.
module SmsGateway
  class Unavailable < StandardError; end

  def self.deliver(phone:, body:)
    backend.deliver(phone: phone, body: body)
  end

  def self.configured?
    backend.configured?
  end

  def self.backend
    case Rails.configuration.x.sms_gateway
    when :log  then Log
    when :test then Test
    else Unconfigured
    end
  end

  # Development: o texto aparece no log do api, com o telefone mascarado como
  # no OtpSender.
  module Log
    def self.configured? = true

    def self.deliver(phone:, body:)
      Rails.logger.info("[sms] #{CitizenIdentity::Phone.mask(phone)} #{body}")
    end
  end

  module Test
    def self.configured? = true

    def self.deliveries
      @deliveries ||= []
    end

    def self.deliver(phone:, body:)
      deliveries << { phone: phone, body: body }
    end

    def self.reset!
      deliveries.clear
    end
  end

  module Unconfigured
    def self.configured? = false

    def self.deliver(**)
      raise Unavailable, "no SMS provider configured"
    end
  end
end
