# "Hoje no CAPS" (ADR 0049; contrato §4): os grupos ativos do dia da semana e
# as matrículas abertas com `next_visit_at` na data local da cidade. Só
# <patient-ref> e <pro>; nada clínico (CID, substância, observação).
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
      rows.map do |group|
        { "id" => group.id, "name" => group.name, "kind" => group.kind, "starts_at" => Json.hour(group.starts_at),
          "ends_at" => Json.hour(group.ends_at), "responsible" => Json.pro(group.responsible_user, cbos[group.responsible_user_id]),
          "capacity" => group.capacity }
      end
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

    private_class_method :groups, :visits
  end
end
