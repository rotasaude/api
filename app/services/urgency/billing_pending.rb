# Pendência sem linha da urgência na competência (ADR 0050; contrato §9 e §14
# Q12): o encontro fechado do provisório ainda não identificado não gera linha
# do BPA (Billing::FromUrgency) e aparece aqui, uma vez por encontro, para a
# recepção identificar o paciente. Entram os encontros fechados da UPA do
# estabelecimento, com classificação (a evasão antes dela não deve nada), fora
# do registro por engano (NON_CARE_OUTCOMES), com o atendimento fechado no
# mês LOCAL da competência e o paciente provisório não fundido. Identificado,
# o encontro sai daqui e as linhas nascem (urgency.patient_identified).
#
# O item tem a forma da pendência do 22 com `procedure_id: null`, o
# `urgency_encounter_id`, o código da classificação e quem a fez; o paciente
# só com o id e o nome de exibição ("Paciente não identificado") — nunca a
# descrição.
module Urgency
  module BillingPending
    REASON = "patient_unidentified".freeze
    FIX = "patient".freeze

    module_function

    # -> Array<Hash> (vazio fora de UPA)
    def call(period)
      unit = period.health_unit_id && HealthUnit.find_by(id: period.health_unit_id)
      return [] unless unit&.upa?

      code = Config.sigtap["classification_code"]
      label = nil
      encounters(unit, period.competence).map do |encounter|
        first = encounter.classifications.first
        patient = encounter.attendance.patient
        label ||= Billing::Labels.procedure(code, period.competence)
        { procedure_id: nil, urgency_encounter_id: encounter.id, reasons: [ REASON ], fix: FIX, late: false,
          performed_on: first.created_at.in_time_zone.to_date.iso8601, sigtap_code: code, label: label,
          patient: { id: patient.id, display_name: patient.display_name, **Patients::IdentifierJson.call(patient),
                     address_from_household: false },
          professional: { user_id: first.classified_by_user_id, name: Screenings::Json.staff_name(first.classified_by_user) } }
      end
    end

    def encounters(unit, competence)
      from = Time.zone.local(competence[0, 4].to_i, competence[4, 2].to_i, 1)
      UrgencyEncounter.where(state: "closed").where.not(current_classification_id: nil)
                      .joins(:outcome, attendance: :patient)
                      .where.not(urgency_outcomes: { kind: Catalog::NON_CARE_OUTCOMES })
                      .where(attendances: { health_unit_id: unit.id, closed_at: from...from.next_month })
                      .where(patients: { unidentified: true, merged_into_id: nil })
                      .includes({ attendance: :patient }, classifications: { classified_by_user: :professional })
                      .order("attendances.closed_at", :id)
    end

    private_class_method :encounters
  end
end
