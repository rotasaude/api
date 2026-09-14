# Envio efetivo do alerta para a secretaria. HTTP/SMTP fora do lock — ADR-0005.
# Hoje suporta apenas e-mail.
#
# Destino: o primeiro AlertRecipient ativo de canal "email" da cidade (ordem de
# escalation_order), no banco da cidade. Antes vinha de Municipality#settings
# (alert_email/alert_webhook); a tabela municipalities não existe no mundo por
# cidade e o city_profile da spec §3 ainda não existe no schema de cidade — o
# provisionamento (Plano 4) é quem o cria. Sem destinatário, levanta: o alerta
# falha visível em vez de sumir.
#
# Dedup contra crash-retry do worker: registra ProcessedEvent
# (consumer="dispatch_alert", event_id="alert:<triage_id>") ANTES da
# entrega externa. RecordNotUnique → skip (já entregue). Pattern espelha
# IdempotentConsumer mas sem o loop do consumer (este job já é CityScopedJob):
# a transação do with_city desfaz o dedup se a entrega levantar, e o retry
# reentrega.
class DispatchMunicipalityAlertJob < ApplicationJob
  include CityScopedJob
  queue_as :urgent
  retry_on Net::SMTPServerBusy, attempts: 5, wait: :polynomially_longer

  CONSUMER = "dispatch_alert".freeze

  class NoAlertRecipient < StandardError; end

  def perform(city_slug:, triage_id:, tier:, priority:, occurred_at:)
    with_city(city_slug) do
      begin
        ProcessedEvent.create!(
          consumer: CONSUMER,
          event_id: "alert:#{triage_id}",
          processed_at: Time.current
        )
      rescue ActiveRecord::RecordNotUnique
        Rails.logger.info("[DispatchMunicipalityAlertJob] skip duplicate triage=#{triage_id}")
        return
      end

      recipient = AlertRecipient.active.find_by(channel: "email")
      raise NoAlertRecipient, "cidade #{city_slug}: nenhum AlertRecipient de e-mail ativo" unless recipient

      AlertMailer.urgent(to: recipient.destination, triage_id: triage_id, tier: tier,
                         priority: priority, occurred_at: occurred_at).deliver_now
    end
  end
end
