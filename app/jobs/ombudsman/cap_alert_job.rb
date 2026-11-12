# Consumidor de ombudsman.anonymous_cap_reached (ADR 0051; contrato §4; §16
# Q21): o primeiro bloqueio do dia pelo teto da denúncia anônima. Roda na
# transação da cidade (IdempotentConsumer): nada de SMTP aqui, só enfileira o
# Ombudsman::MailJob. O payload é {}; o dia é o `run_on` da marca do teto
# (ombudsman_daily_runs, kind anonymous_cap) gravada na mesma transação do
# evento — a mais recente com created_at até o occurred_at do evento —, para
# que o e-mail e a marca nunca discordem do dia (nem na meia-noite, nem no
# consumo atrasado). Sem marca (não deveria acontecer), o dia do occurred_at;
# sem o evento (purgado), o de hoje. Nunca atribui Current.city.
module Ombudsman
  class CapAlertJob < ApplicationJob
    include IdempotentConsumer
    queue_as :default

    def perform(event_id:, **rest)
      @event_id = event_id
      super(event_id: event_id, **rest)
    end

    def handle(**)
      occurred_at = DomainEvent.where(id: @event_id).pick(:occurred_at) || Time.current
      day = OmbudsmanDailyRun.where(kind: RegisterAnonymous::CAP_KIND, created_at: ..occurred_at)
                             .order(created_at: :desc).pick(:run_on) || occurred_at.in_time_zone.to_date
      MailJob.perform_later(city_slug: Current.city.slug, kind: "anonymous_cap", ref: day.iso8601)
    end
  end
end
