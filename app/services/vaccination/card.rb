# A caderneta (contrato §2 `<card>`; §15 V14): a pessoa, a conferência mais
# recente, a versão do calendário, um item por dose do calendário que cabe à
# pessoa (Vaccination::Schedule) e as doses gravadas. Leitura nominal: quem
# chama grava a trilha. Sem conferência, nenhum item é `overdue` (vira
# `unchecked`). Paciente sem nascimento: nenhum item.
#
# items[].applied = { id, applied_at, transcription } (V14) da dose que conta.
# immunizations = todas as doses (canceladas inclusive) na forma <immunization>,
# por applied_at.
module Vaccination
  module Card
    module_function

    def call(patient:, today:, rnds_usable: false, viewer: nil)
      calendar = Calendar.current
      birth = Statuses.birth_date(patient)
      check = VaccinationRecordCheck.where(patient_id: patient.id).order(checked_at: :desc, id: :desc).first
      records = Immunization.where(patient_id: patient.id).order(:applied_at, :id).to_a
      items = birth ? schedule(patient, birth, records, check.present?, today, calendar) : []
      by_id = records.index_by(&:id)

      { patient: { id: patient.id, display_name: patient.display_name, birth_date: patient.birth_date, sex: patient.sex,
                   **Patients::IdentifierJson.call(patient) },
        checked: check && { mode: check.mode, at: check.checked_at, by_name: check.checked_by_user&.professional&.professional_name },
        calendar_version: calendar.version,
        items: items.map { |item| item_json(item, by_id[item.applied_id]) },
        immunizations: Json.immunizations(records, rnds_usable: rnds_usable, viewer: viewer) }
    end

    def schedule(patient, birth, records, checked, today, calendar)
      doses = records.reject(&:cancelled?).map do |record|
        { id: record.id, code: record.immunobiological_code, dose_code: record.dose_code, on: record.applied_at.in_time_zone.to_date }
      end
      Schedule.call(birth_date: birth, sex: patient.sex, pregnant_since: Statuses.pregnant_since(patient), doses: doses,
                    checked: checked, today: today, calendar: calendar)
    end

    def item_json(item, applied)
      code = item.immunobiological_code
      { immunobiological: { code: code, name: Immunobiologicals.find(code)&.name },
        dose: { code: item.dose_code, name: Terminologies.name("dose", item.dose_code) },
        status: item.status, due_on: item.due_on,
        applied: applied && { id: applied.id, applied_at: applied.applied_at, transcription: applied.transcription } }
    end

    private_class_method :schedule, :item_json
  end
end
