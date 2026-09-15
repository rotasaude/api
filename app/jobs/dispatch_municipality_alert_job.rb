# Envio efetivo do alerta para a secretaria. HTTP/SMTP fora do lock — ADR-0005.
# Hoje suporta apenas e-mail.
#
# Destino: o primeiro AlertRecipient ativo de canal "email" da cidade (ordem de
# escalation_order), no banco da cidade. Antes vinha de Municipality#settings
# (alert_email/alert_webhook); a tabela municipalities não existe no mundo por
# cidade, e o city_profile (spec §3, Plano 4) guarda a identidade da cidade, não
# o destino do alerta. Sem destinatário, levanta: o alerta falha visível em vez
# de sumir.
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

  # Erros de rede/SMTP TRANSITÓRIOS: servidor ocupado, timeout, conexão
  # recusada/derrubada, host inalcançável, handshake TLS instável. Vale a
  # pena tentar de novo — a próxima tentativa reabre a conexão/SMTP do zero.
  # O dedup row (ProcessedEvent) desfaz com a transação (ver comentário acima
  # de #perform), então o retry reentrega em vez de pular.
  #
  # Net::SMTPUnknownError (opcional, incluído): a lib Net::SMTP levanta isto
  # quando a resposta do servidor não bate com nenhum código conhecido — não
  # é claramente permanente (má config) nem claramente transitório (glitch de
  # protocolo/servidor). Dado o risco clínico de perder um alerta urgente por
  # um retry que não tentamos, e o custo baixo de tentar mais algumas vezes
  # (5 tentativas, backoff), preferimos tratar como transitório aqui: se for
  # de fato permanente, ainda falha visível depois de esgotar as tentativas.
  #
  # Deliberadamente NÃO incluídos (falham visíveis, sem retry):
  # Net::SMTPFatalError, Net::SMTPSyntaxError (má config/rejeição permanente
  # do servidor), NoAlertRecipient (dado de cidade faltando — retry não
  # resolve), ActionView::MissingTemplate (bug de código — retry não resolve).
  retry_on Net::SMTPServerBusy, Net::SMTPUnknownError, Net::OpenTimeout, Net::ReadTimeout,
           Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH, Timeout::Error,
           EOFError, IOError, OpenSSL::SSL::SSLError,
           attempts: 5, wait: :polynomially_longer

  CONSUMER = "dispatch_alert".freeze

  class NoAlertRecipient < StandardError; end

  def perform(city_slug:, triage_id:, tier:, priority:, occurred_at:)
    with_city(city_slug) do
      # requires_new (SAVEPOINT): sem ele, a violação de unicidade deixa a
      # conexão em "current transaction is aborted" e o `return` abaixo, ao
      # tentar terminar a transação externa do with_city, batia em
      # PG::InFailedSqlTransaction em vez de simplesmente pular (achado do
      # fix round 1 ao testar o caminho de duplicata — mesma classe de bug
      # que M2 corrigiu em IdempotentConsumer).
      begin
        ApplicationRecord.transaction(requires_new: true) do
          ProcessedEvent.create!(
            consumer: CONSUMER,
            event_id: "alert:#{triage_id}",
            processed_at: Time.current
          )
        end
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
