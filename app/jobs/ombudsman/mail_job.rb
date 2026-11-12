# Envio dos e-mails da ouvidoria (ADR 0051; contrato §4). SMTP aqui, fora do
# consumidor de evento (ADR-0005).
#
#   kind "anonymous_cap": ref = data ISO do dia local do bloqueio; lê só a
#                         contagem das denúncias anônimas do canal web do dia.
#
# Dedup no padrão do Surveillance::MailJob: ProcessedEvent (consumer
# "ombudsman_mail", event_id "<kind>:<ref>") ANTES da entrega; a transação do
# with_city o desfaz se a entrega levantar, e o retry reentrega. Um e-mail por
# destinatário (ninguém vê o endereço do outro); recusa permanente do servidor
# pula o endereço e é contada. Não relê o interruptor: o bloqueio só acontece
# pela rota já guardada pelo portão, e o interruptor não se lê dentro da
# transação da cidade. O e-mail leva só a data e a contagem — nunca protocolo,
# texto, unidade nem id; o log, só kind e contagens.
module Ombudsman
  class MailJob < ApplicationJob
    include CityScopedJob
    queue_as :urgent

    # Mesmos erros transitórios do Surveillance::MailJob.
    retry_on Net::SMTPServerBusy, Net::SMTPUnknownError, Net::OpenTimeout, Net::ReadTimeout,
             Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH, Timeout::Error,
             EOFError, IOError, OpenSSL::SSL::SSLError,
             attempts: 5, wait: :polynomially_longer

    CONSUMER = "ombudsman_mail".freeze
    KINDS = %w[anonymous_cap].freeze

    def perform(city_slug:, kind:, ref:)
      raise ArgumentError, "unknown kind" unless KINDS.include?(kind)

      with_city(city_slug) do
        next if duplicate?("#{kind}:#{ref}")

        mails = send("#{kind}_mails", ref)
        next if mails.nil?

        recipients = Recipients.emails(%w[ombudsman])
        delivered, failed = deliver_each(recipients, mails)
        level = failed.positive? ? :warn : :info
        Rails.logger.public_send(level, "[#{self.class.name}] kind=#{kind} recipients=#{recipients.size} delivered=#{delivered} failed=#{failed}")
      end
    end

    private

    def deliver_each(recipients, mails)
      failed = 0
      recipients.each do |to|
        mails.call(to).deliver_now
      rescue Net::SMTPFatalError, Net::SMTPSyntaxError
        failed += 1
      end
      [ recipients.size - failed, failed ]
    end

    # requires_new (SAVEPOINT): ver DispatchMunicipalityAlertJob.
    def duplicate?(event_id)
      ApplicationRecord.transaction(requires_new: true) do
        ProcessedEvent.create!(consumer: CONSUMER, event_id: event_id, processed_at: Time.current)
      end
      false
    rescue ActiveRecord::RecordNotUnique
      Rails.logger.info("[#{self.class.name}] skip duplicate")
      true
    end

    def anonymous_cap_mails(date_string)
      date = Date.iso8601(date_string)
      count = OmbudsmanManifestation.where(channel: "web", identification_mode: "anonymous",
                                           received_at: date.in_time_zone.all_day).count
      return nil if count.zero?

      ->(to) { OmbudsmanMailer.anonymous_cap(to: to, date: date, count: count) }
    end
  end
end
