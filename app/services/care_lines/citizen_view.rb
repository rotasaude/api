# "Meu acompanhamento" (ADR 0040; spec §6; contrato §7, §12 P5a/L9): só as
# linhas em que a pessoa está inscrita; o que está para fazer em linguagem
# simples (citizen_label), sem código, sem sugestão, sem motivo; item não
# rastreado nunca aparece. Triagens periódicas vencidas (módulo 15) junto.
module CareLines
  module CitizenView
    module_function

    def call(citizen:, person:, today:)
      enrollments = person.patient_id ? CareLineEnrollment.active_enrollments.where(patient_id: person.patient_id).order(:enrolled_at).to_a : []
      rows = Evaluation.enrollments(enrollments, today: today)
      lines = enrollments.map do |enrollment|
        items = rows.fetch(enrollment.id).practices.select(&:tracked).map do |status|
          { label: status.citizen_label || status.label, status: status.status, due_on: status.due_on&.iso8601 }
        end
        { name: enrollment.care_line.name, items: items }
      end
      { lines: lines, overdue_triages: overdue_triages(citizen, today) }
    end

    # Só o que o cidadão consegue começar: o mesmo critério do catálogo (sem
    # expirar sugestão nem contar oferta, ao contrário de Triages::Catalog.for):
    # "só por sugestão" exige sugestão pendente e a triagem em andamento do
    # protocolo não conta.
    def overdue_triages(citizen, today)
      items = Triages::Offer.for(citizen: citizen, on: today).select(&:overdue?)
      return [] if items.empty?

      in_progress = Triages::Catalog.in_progress_triage(citizen)&.protocol_name
      pending = TriageSuggestion.status_pending.where(citizen_id: citizen.id).pluck(:protocol_name).to_set
      items.reject { |item| item.protocol_name == in_progress || (item.suggestion_only && !pending.include?(item.protocol_name)) }
           .map { |item| { protocol_name: item.protocol_name, title: item.title, last_done_at: item.last_completed_on.iso8601 } }
    end
  end
end
