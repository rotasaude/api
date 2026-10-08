# app/services/clinical_record/json.rb
# A forma <record> (contratos §3). Sem paciente ainda (par validado que nunca
# consultou), o bloco vem do par com id nulo e as listas vazias (Desvio 10).
# Problemas: ativos primeiro; consultas: as 20 finalizadas mais recentes.
module ClinicalRecord
  module Json
    CONSULTATIONS_LIMIT = 20

    module_function

    def record(patient:, citizen:, grant:, screening: nil)
      { patient: patient_block(patient, citizen), access: grant.kind.to_s,
        problems: patient ? patient.problems.order(Arel.sql("status = 'active' DESC"), :code).map { |p| problem(p) } : [],
        today_screening: screening && Screenings::Json.screening(screening),
        consultations: patient ? recent(patient).map { |c| Consultations::Json.summary(c) } : [] }
    end

    def patient_block(patient, citizen)
      source = patient || citizen
      { id: patient&.id, display_name: source.display_name, full_name: source.full_name, social_name: source.social_name,
        age: source.age, sex: source.sex, cpf_masked: source.cpf_masked }
    end

    def problem(p)
      { id: p.id, terminology: p.terminology, code: p.code, label: ClinicalTerms.label(p.terminology, p.code, p.terminology_release_id),
        status: p.status, onset_on: p.onset_on&.iso8601, onset_precision: p.onset_precision,
        resolved_on: p.resolved_on&.iso8601 }.reject { |k, v| v.nil? && %i[onset_on onset_precision].include?(k) }
    end

    def recent(patient)
      patient.consultations.finalized_consultations.includes(:author_user, :addenda).order(finalized_at: :desc, id: :desc)
             .limit(CONSULTATIONS_LIMIT)
    end
    private_class_method :recent
  end
end
