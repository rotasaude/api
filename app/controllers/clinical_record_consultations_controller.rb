# Leitura administrativa das consultas (decisão do usuário 2026-10-09; contrato
# §9): o municipal_admin vê as consultas FINALIZADAS de cada profissional com o
# conteúdo completo, só leitura (sem impresso, adendo ou edição), sem precisar
# de health_professional. Step-up nas duas rotas. A leitura da consulta deixa
# trilha administrative com o id da consulta (entra no relatório das
# aberturas); a lista não tem conteúdo clínico e não publica trilha.
class ClinicalRecordConsultationsController < ApplicationController
  include Authentication
  include AttendanceAccess
  include ClinicalRecordGate
  include MfaStepUp
  include ReportPeriod

  before_action :require_clinical_record!
  before_action :require_report_role
  before_action :require_step_up!

  def index
    professional = User.find_by(id: params[:user_id])
    return not_found unless professional

    from, to = period
    return render_invalid_period if invalid_period?(from, to)

    list = Consultation.finalized_list(author_user_id: professional.id, from: from, to: to)
    render json: { professional: { id: professional.id, name: Screenings::Json.staff_name(professional) },
                   consultations: list.map { |c| Consultations::Json.list_item(c) } }
  end

  # Rascunho ou inexistente → 404 (nunca vaza rascunho).
  def show
    consultation = Consultation.finalized_consultations.find_by(id: params[:id])
    return not_found unless consultation

    grant = ClinicalRecord::Access::Grant.new(kind: :administrative, opening: nil, reason: nil)
    ClinicalRecord::Trail.viewed!(patient: consultation.patient, user: Current.user, grant: grant,
                                  consultation_id: consultation.id)
    render json: Consultations::Json.consultation(consultation)
  end

  private

  def require_report_role
    forbid("missing_role") unless CitizenVerificationPolicy.new(Current.user, nil).manage?
  end

  def not_found = render(json: { error: "not_found" }, status: :not_found)
end
