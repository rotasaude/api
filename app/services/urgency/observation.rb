# Observação da UPA (ADR 0050; contrato §4 e §12 Q3; plano, Desvios 1 e 2):
# "em observação" = estadia aberta (`ended_at IS NULL`) do encontro num leito.
#
# - `hours`: horas inteiras desde a PRIMEIRA entrada do encontro — a troca de
#   leito e a saída seguida de nova entrada não zeram (A25); `alert`: nil
#   abaixo de 20 h, "near_limit" a partir de 20 h, "over_limit" a partir de
#   24 h. Calculados na leitura, sem tabela, job nem evento; passar de 24 h
#   não bloqueia nada.
# - `board`: o mapa — os leitos ativos da UPA por rótulo (o inativo só se
#   ainda tiver estadia aberta, defensivo: o cadastro recusa desativar
#   ocupado) com a estadia aberta, e `waiting_bed` = os encontros `in_care`
#   da UPA sem estadia aberta, por chamada (A1).
# - `queue_fields`: o `observation` dos itens `in_care` da fila.
#
# Sem texto clínico e sem trilha (é polling). Consultas em lote, nunca uma
# por leito ou por encontro.
module Urgency
  module Observation
    STAY_INCLUDES = { urgency_encounter: { attendance: :patient } }.freeze

    module_function

    # -> Integer (nunca negativo)
    def hours(first_started_at, now) = [ ((now - first_started_at) / 1.hour).floor, 0 ].max

    # -> nil | "near_limit" | "over_limit"
    def alert(hours)
      return "over_limit" if hours >= Catalog::OBSERVATION_LIMIT_HOURS
      return "near_limit" if hours >= Catalog::OBSERVATION_NEAR_LIMIT_HOURS

      nil
    end

    # -> { beds: [{ bed_id, label, active, stay: nil | { stay_id, encounter_id, ticket, patient, started_at, hours, alert } }],
    #      waiting_bed: [{ encounter_id, ticket, patient, called_at }] }
    def board(unit, now: Time.current)
      open = UrgencyBedStay.open_stays.where(health_unit_id: unit.id).includes(STAY_INCLUDES).index_by(&:urgency_bed_id)
      first = first_entries(open.values.map(&:urgency_encounter_id))
      beds = UrgencyBed.where(health_unit_id: unit.id).order(:label, :id).select { |bed| bed.active || open.key?(bed.id) }
      {
        beds: beds.map do |bed|
          stay = open[bed.id]
          { bed_id: bed.id, label: bed.label, active: bed.active, stay: stay && stay_json(stay, first, now) }
        end,
        waiting_bed: waiting_bed(unit).map do |attendance|
          { encounter_id: attendance.urgency_encounter.id, ticket: attendance.ticket, patient: PatientRef.call(attendance.patient),
            called_at: attendance.called_at&.iso8601 }
        end
      }
    end

    # -> { encounter_id => { bed_label, hours, alert } }, só dos que têm estadia aberta.
    def queue_fields(encounter_ids, now: Time.current)
      return {} if encounter_ids.empty?

      open = UrgencyBedStay.open_stays.where(urgency_encounter_id: encounter_ids).includes(:urgency_bed).to_a
      first = first_entries(open.map(&:urgency_encounter_id))
      open.to_h do |stay|
        count = hours(first.fetch(stay.urgency_encounter_id), now)
        [ stay.urgency_encounter_id, { bed_label: stay.urgency_bed.label, hours: count, alert: alert(count) } ]
      end
    end

    # A primeira entrada de cada encontro (todas as estadias, abertas e fechadas).
    def first_entries(encounter_ids)
      return {} if encounter_ids.empty?

      UrgencyBedStay.where(urgency_encounter_id: encounter_ids).group(:urgency_encounter_id).minimum(:started_at)
    end

    def stay_json(stay, first, now)
      encounter = stay.urgency_encounter
      attendance = encounter.attendance
      count = hours(first.fetch(encounter.id), now)
      { stay_id: stay.id, encounter_id: encounter.id, ticket: attendance.ticket, patient: PatientRef.call(attendance.patient),
        started_at: stay.started_at.iso8601, hours: count, alert: alert(count) }
    end

    # Em atendimento na UPA (atendimento e encontro `in_care`) sem estadia aberta.
    def waiting_bed(unit)
      Attendance.where(health_unit_id: unit.id, origin_kind: "walk_in", status: "in_care")
                .joins(:urgency_encounter).where(urgency_encounters: { state: "in_care" })
                .where.not(urgency_encounters: { id: UrgencyBedStay.open_stays.select(:urgency_encounter_id) })
                .order(:called_at, :id).includes(:patient, :urgency_encounter).to_a
    end
    private_class_method :first_entries, :stay_json, :waiting_bed
  end
end
