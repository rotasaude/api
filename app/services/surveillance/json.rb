# Formas JSON da vigilância (contrato §2 `<notification>` e §15 K5). Montadas
# na mão: o as_json dos modelos é redigido de propósito (R18). Quem chama a
# forma nominal grava a trilha (Surveillance::Trail); aqui não há leitura de
# trilha nem dado em log.
module Surveillance
  module Json
    module_function

    # full: true traz `form` e `events` (detalhe e 201); a lista não.
    # diseases: índice code → Disease, para a lista montar uma vez só.
    def notification(n, full: true, diseases: nil)
      json = list_item(n, diseases: diseases)
      return json unless full

      json.merge(form: n.form, events: n.events.includes(:by_user).map { |e| event(e) })
    end

    def list_item(n, diseases: nil)
      { id: n.id, patient: patient(n.patient), disease: disease(n, diseases), origin: n.origin, status: n.status,
        classification: n.classification, suspected_on: n.suspected_on.iso8601, symptoms_on: n.symptoms_on&.iso8601,
        unit: { id: n.health_unit_id, cnes: n.unit_cnes, name: n.health_unit.name },
        notifier: n.notifier_user && { name: Screenings::Json.staff_name(n.notifier_user) },
        deadline: n.deadline, due_at: n.due_at.iso8601, overdue: n.overdue?, official_number: n.official_number,
        resident_elsewhere: n.resident_elsewhere, residence_ibge: n.residence_ibge,
        neighborhood: n.neighborhood && { id: n.neighborhood_id, name: n.neighborhood.name },
        consultation_id: n.consultation_id, closed_at: n.closed_at&.iso8601, entered_at: n.entered_at&.iso8601,
        dismissed_at: n.dismissed_at&.iso8601, version: n.version }
    end

    def patient(patient)
      { id: patient.id, display_name: patient.display_name }.merge(Patients::IdentifierJson.call(patient))
    end

    # Nome da lista em vigor; doença que saiu da lista (versão nova, local
    # desativada) cai para a local por código e, por fim, para o próprio código.
    def disease(n, diseases)
      found = (diseases || Diseases.all.index_by(&:code))[n.disease_code]
      name = found&.name || LocalNotifiableDisease.find_by(code: n.disease_code)&.name || n.disease_code
      { code: n.disease_code, name: name, deadline: n.deadline }
    end

    # Candidato a duplicado (a forma do 24a sem o cadastro territorial).
    def duplicate(patient)
      { patient_id: patient.id, display_name: patient.display_name, birth_date: patient.birth_date, has_cpf: patient.cpf.present? }
    end

    def event(e)
      { status: e.status, at: e.created_at.iso8601, by: e.by_user && { name: Screenings::Json.staff_name(e.by_user) },
        reason: e.reason }
    end
  end
end
