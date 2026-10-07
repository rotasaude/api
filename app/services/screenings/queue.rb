# app/services/screenings/queue.rb
# Fila do acolhimento (ADR 0030; spec §4; contratos §3): atendimentos
# aguardando na unidade que exigem escuta pelo escopo e não têm escuta
# concluída, por chegada. Em curso e abandonada continuam aqui (com o bloco
# da escuta), para a equipe ver quem já está sendo escutado. É também o
# grupo 3 da fila do profissional ("aguardando acolhimento", contrato §9).
module Screenings
  module Queue
    INCLUDES = [ :citizen, :triage, { appointment: { request: :root_triage } },
                 { screening: { started_by_user: :professional } } ].freeze
    # Sem escuta concluída (em curso e abandonada contam como sem).
    NOT_COMPLETED_SQL = "NOT EXISTS (SELECT 1 FROM screenings completed_screenings " \
                        "WHERE completed_screenings.attendance_id = attendances.id " \
                        "AND completed_screenings.status = 'completed')".freeze

    module_function

    def requiring(unit) = Scope.requiring(Attendance.where(health_unit_id: unit.id))

    def pending(unit) = requiring(unit).waiting.where(NOT_COMPLETED_SQL)

    def items(unit) = pending(unit).includes(*INCLUDES).order(:checked_in_at, :id).to_a

    # Marcador "aguardando acolhimento" de um item da fila (mesma regra de
    # pending, em Ruby, sobre o atendimento já carregado).
    def awaiting?(attendance)
      attendance.status == "waiting" && Scope.required?(attendance) && !attendance.screening&.completed?
    end
  end
end
