# Envio efetivo do alerta para a secretaria. HTTP/SMTP fora do lock — ADR-0014.
# Hoje suporta apenas e-mail; canal por município vem de Municipality#settings.
#
# Dedup contra crash-retry do worker: registra ProcessedEvent
# (consumer="dispatch_alert", event_id="alert:<triage_id>") ANTES da
# entrega externa. RecordNotUnique → skip (já entregue). Pattern espelha
# IdempotentConsumer mas sem o tenant-loop do consumer (este job já é
# TenantScopedJob).
class DispatchMunicipalityAlertJob < ApplicationJob
  include TenantScopedJob
  queue_as :urgent
  retry_on Net::SMTPServerBusy, attempts: 5, wait: :polynomially_longer

  CONSUMER = "dispatch_alert".freeze

  def perform(municipality_id:, triage_id:, tier:, priority:, occurred_at:)
    with_tenant(municipality_id) do
      begin
        ProcessedEvent.create!(
          consumer: CONSUMER,
          event_id: "alert:#{triage_id}",
          municipality_id: municipality_id,
          processed_at: Time.current
        )
      rescue ActiveRecord::RecordNotUnique
        Rails.logger.info("[DispatchMunicipalityAlertJob] skip duplicate triage=#{triage_id}")
        return
      end

      municipality = Municipality.find(municipality_id)
      channel = municipality.settings["alert_channel"] || "email"

      case channel
      when "email"
        to = municipality.settings.fetch("alert_email")
        AlertMailer.urgent(to: to, triage_id: triage_id, tier: tier,
                           priority: priority, occurred_at: occurred_at).deliver_now
      when "webhook"
        url = municipality.settings.fetch("alert_webhook")
        Net::HTTP.post(URI(url), {
          triage_id: triage_id, tier: tier,
          priority: priority, occurred_at: occurred_at
        }.to_json, "Content-Type" => "application/json")
      else
        raise "unsupported alert_channel: #{channel}"
      end
    end
  end
end
