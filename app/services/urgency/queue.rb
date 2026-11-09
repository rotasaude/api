# Fila da UPA (ADR 0050; contrato §6 e §14 Q6, Q18; plano, Desvios 9 e 11),
# em três grupos:
#   - awaiting_classification: chegou e ainda não foi classificado, por
#     chegada (o médico nunca chama daqui);
#   - by_color: classificado esperando o médico, pela cor da classificação
#     VIGENTE (COLORS), depois a chegada e o id — reclassificar para cima sobe
#     na hora; `overdue` pelo relógio da 1ª classificação contra o tempo
#     máximo gravado na vigente (UrgencyEncounter#overdue?);
#   - in_care: com o médico, pela hora da chamada.
# A ordem do by_color mora no SQL: a tela e o "chamar próximo"
# (lock_next_classified, FOR UPDATE OF attendances SKIP LOCKED) usam a mesma
# definição, como o Attendances::UnitQueue do 13. Nenhum texto clínico
# (queixa, sinais, dor, justificativa, critério) nem a descrição do não
# identificado; sem trilha (é polling).
module Urgency
  module Queue
    ENCOUNTER_JOIN = "JOIN urgency_encounters queue_encounters ON queue_encounters.attendance_id = attendances.id".freeze
    CLASSIFICATION_JOIN = "JOIN urgency_classifications queue_classifications " \
                          "ON queue_classifications.id = queue_encounters.current_classification_id".freeze
    COLOR_RANK_SQL = "CASE queue_classifications.color " \
                     "#{Catalog::COLORS.each_with_index.map { |color, i| "WHEN '#{color}' THEN #{i}" }.join(' ')} END".freeze
    BY_COLOR_ORDER = Arel.sql("#{COLOR_RANK_SQL} ASC, attendances.checked_in_at ASC, attendances.id ASC").freeze
    INCLUDES = [ :patient, { called_by_user: :professional }, { urgency_encounter: %i[current_classification consultation] } ].freeze

    module_function

    def groups(unit, now: Time.current)
      awaiting = walk_ins(unit.id, "waiting", "waiting_classification").order(:checked_in_at, :id).includes(*INCLUDES).to_a
      by_color = classified(unit.id).includes(*INCLUDES).to_a
      in_care = walk_ins(unit.id, "in_care", "in_care").order(:called_at, :id).includes(*INCLUDES).to_a
      calls = last_calls((awaiting + by_color + in_care).map(&:id))
      {
        awaiting_classification: awaiting.map { |a| item(a, calls, now).merge(max_wait_minutes: nil) },
        by_color: by_color.map { |a| color_item(a, calls, now) },
        in_care: in_care.map { |a| in_care_item(a, calls, now) }
      }
    end

    # O primeiro classificado que ninguém está chamando nem encerrando agora.
    # Chame dentro de uma transação (o lock vale até ela terminar). Quem não
    # foi classificado nunca vem. -> Attendance | nil
    def lock_next_classified(unit_id)
      classified(unit_id).lock("FOR UPDATE OF attendances SKIP LOCKED").first
    end

    def classified(unit_id)
      walk_ins(unit_id, "waiting", "classified").joins(CLASSIFICATION_JOIN).order(BY_COLOR_ORDER)
    end

    def walk_ins(unit_id, status, state)
      Attendance.where(health_unit_id: unit_id, origin_kind: "walk_in", status: status)
                .joins(ENCOUNTER_JOIN).where(queue_encounters: { state: state })
    end

    # A chamada mais recente de cada atendimento, com o nome do local.
    def last_calls(attendance_ids)
      return {} if attendance_ids.empty?

      AttendanceCall.where(attendance_id: attendance_ids).includes(:call_location)
                    .select("DISTINCT ON (attendance_id) attendance_calls.*")
                    .order(:attendance_id, called_at: :desc, id: :desc).index_by(&:attendance_id)
    end

    def item(attendance, calls, now)
      call = calls[attendance.id]
      {
        encounter_id: attendance.urgency_encounter.id, attendance_id: attendance.id, ticket: attendance.ticket,
        patient: PatientRef.call(attendance.patient), arrived_at: attendance.checked_in_at.iso8601,
        waited_minutes: ((now - attendance.checked_in_at) / 60).floor,
        last_call: call && { kind: call.kind, location: call.call_location&.name, called_at: call.called_at.iso8601 }
      }
    end

    # `classified_at` é a 1ª classificação: o relógio do estouro (Desvio 9).
    def color_item(attendance, calls, now)
      encounter = attendance.urgency_encounter
      current = encounter.current_classification
      item(attendance, calls, now).merge(color: current.color, max_wait_minutes: current.max_wait_minutes,
                                         overdue: encounter.overdue?(at: now),
                                         classified_at: encounter.first_classified_at.iso8601)
    end

    # Em atendimento nunca estoura (UrgencyEncounter#overdue? só em classified).
    def in_care_item(attendance, calls, now)
      encounter = attendance.urgency_encounter
      current = encounter.current_classification
      item(attendance, calls, now).merge(color: current&.color, max_wait_minutes: current&.max_wait_minutes,
                                         called_at: attendance.called_at&.iso8601,
                                         called_by_name: Screenings::Json.staff_name(attendance.called_by_user),
                                         consultation_id: encounter.consultation_id,
                                         consultation_status: encounter.consultation&.status)
    end
    private_class_method :classified, :walk_ins, :last_calls, :item, :color_item, :in_care_item
  end
end
