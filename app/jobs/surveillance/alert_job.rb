# Consumidor de disease_notification.created (módulo 25, ADR 0043): só as
# imediatas geram alerta por e-mail; a semanal espera o resumo diário das
# vencidas. Roda na transação da cidade (IdempotentConsumer): nada de SMTP
# aqui, só enfileira o Surveillance::MailJob (fila urgent). O payload traz
# notification_id e immediate; origem e situação vêm da linha, no MailJob.
# Nunca atribui Current.city.
module Surveillance
  class AlertJob < ApplicationJob
    include IdempotentConsumer
    queue_as :default

    def handle(notification_id:, immediate:, **)
      return unless immediate == true && Gate.enabled?(Current.city)

      MailJob.perform_later(city_slug: Current.city.slug, kind: "immediate", ref: notification_id)
    end
  end
end
