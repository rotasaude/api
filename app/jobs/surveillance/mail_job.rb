# Envio dos e-mails da vigilância (módulo 25, ADR 0043): imediata, vencidas e
# lembrete da negativa. SMTP aqui, fora do consumidor de evento (ADR-0005).
#
#   kind "immediate": ref = id da notificação; lê doença, unidade e se ainda é
#                     possível (situação da LINHA, não do evento);
#   kind "overdue":   ref = data ISO do dia na cidade; lê só contagens;
#   kind "negatives": ref = semana "YYYY-WW"; lê os nomes das unidades pendentes.
#
# Dedup como o DispatchMunicipalityAlertJob: ProcessedEvent
# (consumer "surveillance_mail", event_id "<kind>:<ref>") ANTES da entrega; a
# transação do with_city o desfaz se a entrega levantar, e o retry reentrega.
# Um e-mail por destinatário (ninguém vê o endereço do outro). Endereço que o
# servidor recusa de vez (Net::SMTPFatalError/SMTPSyntaxError) é pulado e
# contado, sem calar os demais; erro transitório levanta e o retry reenvia
# também aos que já receberam (duplicata aceita: melhor repetir que perder).
# Sem destinatário: log com a contagem 0 e sem erro — o painel segue mostrando o
# alerta. O e-mail nunca leva paciente, bairro, data de sintomas nem id; o log
# só tem kind e contagens (nunca doença, unidade ou paciente).
module Surveillance
  class MailJob < ApplicationJob
    include CityScopedJob
    queue_as :urgent

    # Mesmos erros transitórios do DispatchMunicipalityAlertJob (ver o porquê lá).
    retry_on Net::SMTPServerBusy, Net::SMTPUnknownError, Net::OpenTimeout, Net::ReadTimeout,
             Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH, Timeout::Error,
             EOFError, IOError, OpenSSL::SSL::SSLError,
             attempts: 5, wait: :polynomially_longer

    CONSUMER = "surveillance_mail".freeze
    KINDS = %w[immediate overdue negatives].freeze

    def perform(city_slug:, kind:, ref:)
      raise ArgumentError, "unknown kind" unless KINDS.include?(kind)

      with_city(city_slug) do
        next if duplicate?("#{kind}:#{ref}")
        # immediate não relê o portão: o AlertJob já o conferiu ao enfileirar, e
        # um alerta aceito não some porque o interruptor virou no intervalo.
        next if kind != "immediate" && !Gate.usable?(Current.city)

        mails = send("#{kind}_mails", ref)
        next if mails.nil? # nada a dizer agora (notificação sumiu, contagem zerou, ninguém pendente)

        recipients = Recipients.emails
        delivered, failed = deliver_each(recipients, mails)
        Rails.logger.info("[#{self.class.name}] kind=#{kind} recipients=#{recipients.size} delivered=#{delivered} failed=#{failed}")
      end
    end

    private

    # -> [entregues, recusados]. Só recusa permanente pula o endereço; o log
    # nunca leva o endereço.
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

    # Cada *_mails devolve um lambda (to) -> mensagem, ou nil se não há o que enviar.
    def immediate_mails(notification_id)
      notification = DiseaseNotification.includes(:health_unit).find_by(id: notification_id)
      return nil if notification.nil?

      disease = Json.disease(notification, nil).fetch(:name)
      unit = notification.health_unit.name
      possible = notification.status == "possible"
      ->(to) { SurveillanceMailer.immediate(to: to, disease_label: disease, unit_label: unit, possible: possible) }
    end

    def overdue_mails(_date)
      overdue = DiseaseNotification.overdue_at(Time.current)
      count = overdue.count
      return nil if count.zero?

      immediate = overdue.where(deadline: "immediate").count
      ->(to) { SurveillanceMailer.overdue(to: to, count: count, immediate_count: immediate) }
    end

    def negatives_mails(week_string)
      week = EpiWeek.parse(week_string) || raise(ArgumentError, "invalid week")
      labels = WeekCases.pending_units(week).map(&:name)
      return nil if labels.empty?

      ->(to) { SurveillanceMailer.negatives(to: to, week: week.to_s, unit_labels: labels) }
    end
  end
end
