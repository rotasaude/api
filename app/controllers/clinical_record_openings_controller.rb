# Abertura justificada (step-up) e o relatório das aberturas (municipal_admin)
# (ADR 0031; spec §5; contratos §3). O relatório nunca mostra a nota. Desde a
# decisão do usuário de 2026-10-09 (contrato §9) ele traz também as leituras
# administrativas (kind administrative_read), lidas da tabela
# clinical_record_administrative_reads (Task 23: guardadas para sempre).
class ClinicalRecordOpeningsController < ApplicationController
  include Authentication
  include AttendanceAccess
  include ClinicalRecordGate
  include MfaStepUp
  include ReportPeriod

  REPORT_LIMIT = 500
  ERROR_STATUS = { missing_role: :forbidden, missing_link: :forbidden, cbo_not_allowed: :forbidden,
                   patient_not_found: :not_found, invalid_reason: :unprocessable_entity }.freeze

  before_action :require_clinical_record!
  before_action :require_professional, only: :create
  before_action :require_report_role, only: :index

  def create
    return require_step_up! unless reauthenticated_recently?

    result = ClinicalRecord::Open.call(user: Current.user, cpf: params[:cpf], reason_code: params[:reason_code],
                                       reason_note: params[:reason_note])
    return render_failure(result, ERROR_STATUS) if result.failure?

    opening = result.payload[:opening]
    render json: { opening_id: opening.id, patient_id: opening.patient_id, expires_at: opening.expires_at.iso8601 },
           status: :created
  end

  # Aberturas e leituras administrativas, mais novas primeiro, até
  # REPORT_LIMIT no total, com os mesmos filtros.
  def index
    from, to = period
    return render_invalid_period if invalid_period?(from, to)

    user_id = params[:user_id] if params[:user_id].is_a?(String) && params[:user_id].present?
    # [instante, id, item]: ordena pelo instante completo (o item leva só segundos).
    rows = openings(from, to, user_id).map { |o| [ o.created_at, o.id, item(o) ] } + administrative_reads(from, to, user_id)
    render json: { items: rows.sort_by { |at, id, _| [ at, id ] }.reverse.first(REPORT_LIMIT).map(&:last) }
  end

  private

  def require_report_role
    forbid("missing_role") unless CitizenVerificationPolicy.new(Current.user, nil).manage?
  end

  def openings(from, to, user_id)
    scope = ClinicalRecordOpening.includes(:patient, user: :professional).order(created_at: :desc, id: :desc).limit(REPORT_LIMIT)
    scope = scope.where(created_at: from..) if from
    scope = scope.where(created_at: ..to) if to
    user_id ? scope.where(user_id: user_id) : scope
  end

  def item(opening)
    { kind: "justified_opening", id: opening.id, user_name: Screenings::Json.staff_name(opening.user),
      cpf_masked: opening.patient.cpf_masked, reason_code: opening.reason_code, consultation_id: nil,
      created_at: opening.created_at.iso8601, expires_at: opening.expires_at.iso8601 }
  end

  # Lidas de clinical_record_administrative_reads (Task 23), guardadas para
  # sempre — não da trilha, que a purga de 12 meses leva. A linha só tem ids:
  # nome e CPF mascarado vêm das tabelas, carregados com ela.
  def administrative_reads(from, to, user_id)
    scope = ClinicalRecordAdministrativeRead.includes(:patient, user: :professional)
                                            .order(created_at: :desc, id: :desc).limit(REPORT_LIMIT)
    scope = scope.where(created_at: from..) if from
    scope = scope.where(created_at: ..to) if to
    scope = scope.where(user_id: user_id) if user_id
    scope.map { |read| [ read.created_at, read.id, administrative_item(read) ] }
  end

  def administrative_item(read)
    { kind: "administrative_read", id: read.id, user_name: Screenings::Json.staff_name(read.user),
      cpf_masked: read.patient.cpf_masked, reason_code: nil, consultation_id: read.consultation_id,
      created_at: read.created_at.iso8601, expires_at: nil }
  end
end
