# Envio efetivo do alerta para a secretaria. HTTP/SMTP fora do lock — ADR-0014.
# Hoje suporta apenas e-mail; canal por município vem de Municipality#settings.
class DispatchMunicipalityAlertJob < ApplicationJob
  queue_as :urgent
  retry_on Net::SMTPServerBusy, attempts: 5, wait: :polynomially_longer

  def perform(municipality_id:, triagem_id:, tier:, priority:, occurred_at:)
    municipality = Municipality.find(municipality_id)
    channel = municipality.settings["alert_channel"] || "email"

    case channel
    when "email"
      to = municipality.settings.fetch("alert_email")
      AlertMailer.urgent(to: to, triagem_id: triagem_id, tier: tier,
                         priority: priority, occurred_at: occurred_at).deliver_now
    when "webhook"
      url = municipality.settings.fetch("alert_webhook")
      Net::HTTP.post(URI(url), {
        triagem_id: triagem_id, tier: tier,
        priority: priority, occurred_at: occurred_at
      }.to_json, "Content-Type" => "application/json")
    else
      raise "unsupported alert_channel: #{channel}"
    end
  end
end
