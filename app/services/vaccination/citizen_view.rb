# A caderneta do cidadão (contrato §9; §15 V11/V17, W1-W6). Forma fixa e sem
# o que é da sala: nunca lote, vacinador, motivo nem dose cancelada.
#
#   { checked, items: [ { immunobiological_name, dose_name, applied_on,
#                         place_name|null, transcription, rnds: "sent"|"sending" } ],
#     upcoming: [ { immunobiological_name, dose_name, due_on } ] }
#
# items por applied_on DECRESCENTE; upcoming por due_on CRESCENTE, datas nulas
# no fim; datas AAAA-MM-DD no fuso da cidade. `rnds` é "sent" só com a entrada
# `application` aceita pela RNDS; todo o resto (na fila, enviando, bloqueada,
# recusada, falha, desligado) é "sending": o cidadão nunca vê "enviada" uma
# dose que não foi. `place_name` é a unidade da sala (nula na transcrição, cujo
# local é texto livre). `upcoming` só com caderneta conferida (senão, []); uma
# próxima dose com data passada é permitida (W6). Leitura nominal: quem chama
# grava a trilha. Sem paciente: caderneta vazia e não conferida.
module Vaccination
  module CitizenView
    UPCOMING = %w[due upcoming overdue].freeze

    module_function

    def call(patient_id:, today: Time.zone.today)
      patient = patient_id && Patient.find_by(id: patient_id)
      return { checked: false, items: [], upcoming: [] } unless patient

      checked = VaccinationRecordCheck.where(patient_id: patient.id).exists?
      { checked: checked, items: items(patient), upcoming: checked ? upcoming(patient, today) : [] }
    end

    def items(patient)
      records = Immunization.active.includes(:health_unit).where(patient_id: patient.id).order(applied_at: :desc, id: :asc).to_a
      accepted = RndsOutboxEntry.where(immunization_id: records.map(&:id), kind: "application", status: "accepted").pluck(:immunization_id).to_set
      records.map do |record|
        { immunobiological_name: Immunobiologicals.find(record.immunobiological_code)&.name,
          dose_name: Terminologies.name("dose", record.dose_code),
          applied_on: record.applied_at.in_time_zone.to_date.iso8601,
          place_name: record.transcription ? nil : record.health_unit.name,
          transcription: record.transcription,
          rnds: accepted.include?(record.id) ? "sent" : "sending" }
      end
    end

    def upcoming(patient, today)
      birth = Statuses.birth_date(patient)
      return [] unless birth

      records = Immunization.active.where(patient_id: patient.id).order(:applied_at, :id).to_a
      doses = records.map { |r| { id: r.id, code: r.immunobiological_code, dose_code: r.dose_code, on: r.applied_at.in_time_zone.to_date } }
      list = Schedule.call(birth_date: birth, sex: patient.sex, pregnant_since: Statuses.pregnant_since(patient), doses: doses,
                           checked: true, today: today, calendar: Calendar.current)
      rows = list.select { |item| UPCOMING.include?(item.status) }.map do |item|
        { immunobiological_name: Immunobiologicals.find(item.immunobiological_code)&.name,
          dose_name: Terminologies.name("dose", item.dose_code), due_on: item.due_on&.iso8601 }
      end
      rows.sort_by { |row| [ row[:due_on] ? 0 : 1, row[:due_on].to_s, row[:immunobiological_name].to_s, row[:dose_name].to_s ] }
    end

    private_class_method :items, :upcoming
  end
end
