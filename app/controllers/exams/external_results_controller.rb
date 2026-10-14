# POST /exams/external_results (contrato §3, A9): profissional com leitura do
# paciente (regra do 19a) ou recepção; consultation_id só da própria autora.
# Autoriza antes de gravar: o papel primeiro; o paciente (Patients::Resolve
# escreve) só dentro da transação, que desfaz tudo numa recusa. A leitura
# clínica deixa a trilha do 19a, só ids.
module Exams
  class ExternalResultsController < BaseController
    def create
      professional = Current.user.has_role?("health_professional")
      return forbid("missing_role") unless professional || Current.user.has_role?("citizen_verifier")

      outcome = nil
      ApplicationRecord.transaction do
        outcome = record(professional)
        raise ActiveRecord::Rollback unless outcome.is_a?(Hash)
      end
      return outcome.call if outcome.respond_to?(:call)

      ClinicalRecord::Trail.viewed!(patient: outcome[:result].patient, user: Current.user, grant: outcome[:grant],
                                    extra: { exam_result_id: outcome[:result].id }) if outcome[:view] == :clinical
      render json: Exams::Json.result(outcome[:result], view: outcome[:view], user: Current.user), status: :created
    end

    def index
      # Papel antes de achar o paciente: sem ele, 403 igual para paciente que existe ou não.
      return forbid("missing_role") unless Current.user.has_role?("health_professional")

      patient = uuid?(params[:patient_id]) && Patient.find_by(id: params[:patient_id])
      return not_found unless patient

      grant = ClinicalRecord::Access.call(user: Current.user, patient: patient)
      return forbid(grant.reason.to_s) unless grant.allowed?

      rows = ExamResult.where(patient_id: patient.id, origin: "external").includes(:pdf_file, exam_order: :events)
                       .order(created_at: :desc, id: :desc).limit(100).to_a
      ClinicalRecord::Trail.viewed!(patient: patient, user: Current.user, grant: grant, extra: { exam_result_ids: rows.map(&:id) })
      results = rows.map do |result|
        Exams::Json.result(result, view: :clinical, user: Current.user)
                   .merge(sigtap_code: result.sigtap_code, label: Exams::Labels.exam(result.sigtap_code, result.released_on.strftime("%Y%m")))
      end
      render json: { results: results }
    end

    private

    # Hash em caso de sucesso; senão um lambda que desenha a recusa (depois do rollback).
    def record(professional)
      patient = Exams::GuideInput.patient_from(body_params.symbolize_keys)
      return -> { render_failure(patient) } if patient.is_a?(Result)

      grant = professional ? ClinicalRecord::Access.call(user: Current.user, patient: patient) : nil
      view = grant&.allowed? ? :clinical : :administrative
      unless grant&.allowed? || Current.user.has_role?("citizen_verifier")
        return -> { forbid(grant.reason.to_s) }
      end

      consultation = nil
      if params[:consultation_id].present?
        consultation = uuid?(params[:consultation_id]) &&
                       Consultation.find_by(id: params[:consultation_id], patient_id: patient.id, author_user_id: Current.user.id)
        return -> { not_found } unless consultation
      end
      result = Exams::RecordExternalResult.call(patient: patient, sigtap_code: params[:sigtap_code], released_on: params[:released_on],
                                                laboratory_name: params[:laboratory_name], file_id: params[:upload_id],
                                                values: params[:values], by: Current.user, consultation: consultation)
      return -> { render_failure(result) } if result.failure?

      { result: result.payload[:result], view: view, grant: grant }
    end
  end
end
