# Resumo diário das vencidas (módulo 25, ADR 0043): por cidade com o módulo
# utilizável, se há notificação vencida (a mesma regra da fila: prazo passado e
# situação possible/notified) enfileira UM e-mail só com contagens
# (Surveillance::MailJob kind "overdue", ref = o dia na cidade — o dedup do
# MailJob segura uma segunda execução no mesmo dia).
module Surveillance
  class OverdueJob < ApplicationJob
    prepend EachCityJob
    queue_as :housekeeping

    def perform
      return unless Gate.usable?(Current.city)
      return unless DiseaseNotification.overdue_at(Time.current).exists?

      MailJob.perform_later(city_slug: Current.city.slug, kind: "overdue", ref: Time.zone.today.iso8601)
    end
  end
end
