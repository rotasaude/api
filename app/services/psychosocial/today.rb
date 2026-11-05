# "Hoje no CAPS" (ADR 0049; contrato §4): os grupos ativos do dia da semana e
# as matrículas abertas com `next_visit_at` na data local da cidade. Só
# <patient-ref> e <pro>; nada clínico (CID, substância, observação). Cada
# grupo leva o `sigtap_code` e o `action_id` (P56): a ação não cancelada do
# grupo com data local igual à pedida (a mais antiga, se houver mais de uma), ou nulo.
module Psychosocial
  module Today
    module_function

    # date: Date local. -> { "date", "groups", "visits" }
    def call(unit:, date:)
      { "date" => Json.date(date), "groups" => groups(unit, date), "visits" => visits(unit, date) }
    end

    def groups(unit, date)
      rows = PsychosocialGroup.where(health_unit_id: unit.id, active: true, weekday: date.cwday)
                              .includes(responsible_user: :professional).order(:starts_at, :id).to_a
      cbos = Access.cbos(rows.map(&:responsible_user_id), unit.id)
      actions = group_actions(rows.map(&:id), date)
      rows.map do |group|
        { "id" => group.id, "name" => group.name, "kind" => group.kind, "starts_at" => Json.hour(group.starts_at),
          "ends_at" => Json.hour(group.ends_at), "responsible" => Json.pro(group.responsible_user, cbos[group.responsible_user_id]),
          "capacity" => group.capacity, "sigtap_code" => group.sigtap_code, "action_id" => actions[group.id] }
      end
    end

    # { group_id => action_id } da ação não cancelada do grupo no dia local.
    def group_actions(group_ids, date)
      return {} if group_ids.empty?

      from = date.in_time_zone
      PsychosocialAction.where(psychosocial_group_id: group_ids, cancelled_at: nil, performed_at: from...(from + 1.day))
                        .order(:performed_at, :id).pluck(:psychosocial_group_id, :id)
                        .each_with_object({}) { |(group_id, id), out| out[group_id] ||= id }
    end

    # O dia é o local (23:30 de hoje não é amanhã em UTC).
    def visits(unit, date)
      from = date.in_time_zone
      rows = PsychosocialEnrollment.open_enrollments.where(health_unit_id: unit.id, next_visit_at: from...(from + 1.day))
                                   .includes(:patient, reference_user: :professional).order(:next_visit_at, :id).to_a
      cbos = Access.cbos(rows.map(&:reference_user_id), unit.id)
      rows.map do |enrollment|
        { "enrollment_id" => enrollment.id, "patient" => Json.patient_ref(enrollment.patient),
          "next_visit_at" => Json.time(enrollment.next_visit_at),
          "reference" => Json.pro(enrollment.reference_user, cbos[enrollment.reference_user_id]) }
      end
    end

    private_class_method :groups, :group_actions, :visits
  end
end
