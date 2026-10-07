# Fila da unidade (spec 2026-09-25 §6; ADR 0030 §4; contrato §9 do módulo 18).
# Aguardando, em três grupos:
#   1. escuta concluída same_day (os outros destinos já fecharam o
#      atendimento), pela cor da revisão corrente (red, yellow, green, blue);
#   2. quem não exige escuta pelo escopo da unidade (ex.: horário em walk_in);
#   3. quem ainda aguarda a escuta (exige e não tem escuta concluída; em curso
#      e abandonada contam) — ninguém é pulado, só vem depois.
# Nos grupos 2 e 3 vale a ordem do módulo 13: prioridade da triagem raiz (a
# própria, ou a do pedido do horário; sem prioridade por último). Em todos,
# depois a chegada e, no empate, o id. Em atendimento por hora da chamada.
# A exigência reusa o SQL de Screenings::Scope/Queue (uma só definição). A
# ordem mora no SQL para o "chamar próximo" travar o primeiro disponível com
# FOR UPDATE OF attendances SKIP LOCKED na MESMA ordem que a tela mostra.
module Attendances
  module UnitQueue
    INCLUDES = [ :citizen, :health_unit, { called_by_user: :professional }, :triage,
                 { appointment: { request: :root_triage } }, { screening: :current_revision } ].freeze

    ROOT_TRIAGE_JOINS = <<~SQL.squish.freeze
      LEFT JOIN triages queue_triages ON queue_triages.id = attendances.triage_id
      LEFT JOIN appointments queue_appointments ON queue_appointments.id = attendances.appointment_id
      LEFT JOIN appointment_requests queue_requests ON queue_requests.id = queue_appointments.request_id
      LEFT JOIN triages queue_root_triages ON queue_root_triages.id = queue_requests.root_triage_id
      LEFT JOIN screenings queue_screenings ON queue_screenings.attendance_id = attendances.id
        AND queue_screenings.status = 'completed' AND queue_screenings.destination = 'same_day'
      LEFT JOIN screening_revisions queue_revisions ON queue_revisions.id = queue_screenings.current_revision_id
      #{Screenings::Scope::UNITS_JOIN}
    SQL
    SCREENED_SQL = "queue_screenings.id IS NOT NULL".freeze
    TIER_SQL = "CASE WHEN #{SCREENED_SQL} THEN 1 " \
               "WHEN #{Screenings::Scope::REQUIRED_SQL} AND #{Screenings::Queue::NOT_COMPLETED_SQL} THEN 3 " \
               "ELSE 2 END".freeze
    ORDER = Arel.sql(
      "#{TIER_SQL} ASC, " \
      "CASE queue_revisions.final_color WHEN 'red' THEN 0 WHEN 'yellow' THEN 1 WHEN 'green' THEN 2 " \
      "WHEN 'blue' THEN 3 END ASC NULLS LAST, " \
      "CASE WHEN #{SCREENED_SQL} THEN NULL " \
      "ELSE COALESCE(queue_triages.priority, queue_root_triages.priority) END ASC NULLS LAST, " \
      "attendances.checked_in_at ASC, attendances.id ASC"
    ).freeze

    module_function

    def ordered_waiting(unit_id)
      Attendance.waiting.where(health_unit_id: unit_id).joins(ROOT_TRIAGE_JOINS).order(ORDER)
    end

    def waiting(unit_id)
      ordered_waiting(unit_id).includes(*INCLUDES).to_a
    end

    # O primeiro da fila que ninguém está chamando ou encerrando agora. Chame
    # dentro de uma transação: o lock vale até ela terminar. Se todas as linhas
    # aguardando estiverem travadas por outras transações, devolve nil mesmo com
    # fila (por milissegundos).
    def lock_next_waiting(unit_id)
      ordered_waiting(unit_id).lock("FOR UPDATE OF attendances SKIP LOCKED").first
    end

    def in_care(unit_id)
      Attendance.in_care.where(health_unit_id: unit_id).includes(*INCLUDES).order(:called_at, :id).to_a
    end
  end
end
