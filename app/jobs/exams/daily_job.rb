# Job diário do rastreamento (ADR 0036; spec §5): ciência vencida vai à fila
# da equipe (escalated overdue) só nos exames AINDA NÃO escalados por motivo
# nenhum (escalated_at nulo; o já escalado por critical/unlinked_requester não
# ganha overdue — A31 permite, mas não exige); arquivos nunca usados com mais
# de 24 h somem (guia/laudo abandonados no upload). Dias no fuso da cidade
# (CityConnection.with → Time.zone). O trigger exam_files_guard só recusa
# apagar arquivo consumido.
module Exams
  class DailyJob < ApplicationJob
    prepend EachCityJob
    queue_as :housekeeping

    ORPHAN_TTL = 24.hours

    def perform(now: Time.current)
      ExamFile.where(consumed_at: nil).where("created_at < ?", now - ORPHAN_TTL).delete_all
      return unless Exams::Gate.usable?(Current.city)

      today = now.in_time_zone.to_date
      ExamOrder.where(status: "resulted", escalated_at: nil).where("stage_due_on < ?", today).find_each do |order|
        ApplicationRecord.transaction do
          order.lock!
          Exams::Escalate.call(order: order, reason: "overdue", now: now) if order.status == "resulted"
        end
      end
    end
  end
end
