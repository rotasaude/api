# Fila da unidade (spec 2026-09-25 §6): aguardando por prioridade (da
# triagem raiz) e chegada; em atendimento por hora da chamada.
module Attendances
  module UnitQueue
    INCLUDES = [ :citizen, :called_by_user, :triage, { appointment: { request: :root_triage } } ].freeze

    module_function

    def waiting(unit_id)
      Attendance.waiting.where(health_unit_id: unit_id).includes(*INCLUDES).to_a
                .sort_by { |a| [ a.priority || 999, a.checked_in_at ] }
    end

    def in_care(unit_id)
      Attendance.in_care.where(health_unit_id: unit_id).includes(*INCLUDES).order(:called_at).to_a
    end
  end
end
