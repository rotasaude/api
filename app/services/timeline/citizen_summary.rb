# Resumo clínico do cidadão (ADR 0035; spec §4; contrato §4). Só com
# paciente e prontuário utilizável (quem chama confere). Problema sem nome
# na release gravada não aparece (nunca CID sem nome). Exame: por consulta e
# código vale a linha mais recente (o adendo cancela com uma linha
# `cancelled`); entram as `requested` dos últimos 12 meses. Sinais: a
# aferição mais recente entre consultas finalizadas e escutas concluídas.
module Timeline
  module CitizenSummary
    EXAM_WINDOW = 12.months

    module_function

    def call(patient:, person:, now: Time.current)
      { problems: problems(patient), medications: medications(patient), exam_requests: exam_requests(patient, now),
        vitals: vitals(patient, person) }
    end

    def problems(patient)
      patient.problems.where(status: "active").order(:terminology, :code).filter_map do |problem|
        label = ClinicalTerms.label(problem.terminology, problem.code, problem.terminology_release_id)
        label && { terminology: problem.terminology, code: problem.code, label: label, since: problem.onset_on&.iso8601 }
      end
    end

    def medications(patient)
      PatientMedication.where(patient_id: patient.id, status: "active").order(:created_at, :id).map do |medication|
        { label: medication.label, dosage_summary: medication.dosage_summary, since: medication.started_on&.iso8601 }
      end
    end

    def exam_requests(patient, now)
      rows = ConsultationExamRequest.joins(:consultation)
                                    .where(consultations: { patient_id: patient.id, status: "finalized" })
                                    .where("consultation_exam_requests.created_at >= ?", now - EXAM_WINDOW)
                                    .order(:created_at, :id).to_a
      latest = rows.group_by { |row| [ row.consultation_id, row.sigtap_code ] }.values.map(&:last)
      latest.select { |row| row.status == "requested" }.sort_by { |row| [ -row.created_at.to_r, row.id ] }.map do |row|
        { sigtap_code: row.sigtap_code,
          label: ClinicalTerms::SigtapExams.label(row.sigtap_code, row.sigtap_competence) || "Procedimento #{row.sigtap_code}",
          requested_at: row.created_at.iso8601 }
      end
    end

    def vitals(patient, person)
      out = {}
      bp, at = latest(patient, person, :systolic)
      out[:blood_pressure] = { systolic: bp.systolic, diastolic: bp.diastolic, measured_at: at.iso8601 } if bp
      weight, at = latest(patient, person, :weight_kg)
      out[:weight_kg] = { value: weight.weight_kg.to_f, measured_at: at.iso8601 } if weight
      glucose, at = latest(patient, person, :capillary_glucose)
      out[:capillary_glucose] = { value: glucose.capillary_glucose, moment: glucose.glucose_moment, measured_at: at.iso8601 } if glucose
      out
    end

    # [registro, instante] da aferição mais recente da coluna, ou nil.
    def latest(patient, person, column)
      consultation = Consultation.finalized_consultations.where(patient_id: patient.id).where.not(column => nil)
                                 .order(finalized_at: :desc, id: :asc).first
      revision = ScreeningRevision.joins(screening: :attendance)
                                  .where(screenings: { status: "completed" }, attendances: { citizen_id: person.citizen_ids })
                                  .where("screenings.current_revision_id = screening_revisions.id")
                                  .where.not(column => nil).order("screenings.completed_at DESC").includes(:screening).first
      [ consultation && [ consultation, consultation.finalized_at ], revision && [ revision, revision.screening.completed_at ] ]
        .compact.max_by { |_, at| at }
    end
    private_class_method :latest
  end
end
