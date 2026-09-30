# Fila da unidade (spec 2026-09-25 §6): aguardando pela prioridade da triagem
# raiz (a própria, ou a do pedido do horário; sem prioridade por último),
# depois pela chegada e, no empate, pelo id; em atendimento por hora da
# chamada. A ordem mora no SQL para o "chamar próximo" travar o primeiro
# disponível com FOR UPDATE SKIP LOCKED na MESMA ordem que a tela mostra.
module Attendances
  module UnitQueue
    INCLUDES = [ :citizen, { called_by_user: :professional }, :triage, { appointment: { request: :root_triage } } ].freeze

    ROOT_TRIAGE_JOINS = <<~SQL.squish.freeze
      LEFT JOIN triages queue_triages ON queue_triages.id = attendances.triage_id
      LEFT JOIN appointments queue_appointments ON queue_appointments.id = attendances.appointment_id
      LEFT JOIN appointment_requests queue_requests ON queue_requests.id = queue_appointments.request_id
      LEFT JOIN triages queue_root_triages ON queue_root_triages.id = queue_requests.root_triage_id
    SQL
    ORDER = Arel.sql("COALESCE(queue_triages.priority, queue_root_triages.priority) ASC NULLS LAST, " \
                     "attendances.checked_in_at ASC, attendances.id ASC").freeze

    module_function

    def ordered_waiting(unit_id)
      Attendance.waiting.where(health_unit_id: unit_id).joins(ROOT_TRIAGE_JOINS).order(ORDER)
    end

    def waiting(unit_id)
      ordered_waiting(unit_id).includes(*INCLUDES).to_a
    end

    # O primeiro da fila que ninguém está chamando ou encerrando agora. Chame
    # dentro de uma transação: o lock vale até ela terminar.
    def lock_next_waiting(unit_id)
      ordered_waiting(unit_id).lock("FOR UPDATE OF attendances SKIP LOCKED").first
    end

    def in_care(unit_id)
      Attendance.in_care.where(health_unit_id: unit_id).includes(*INCLUDES).order(:called_at, :id).to_a
    end
  end
end
