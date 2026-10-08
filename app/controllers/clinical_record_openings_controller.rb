# Abertura justificada (step-up) e o relatório das aberturas (municipal_admin)
# (ADR 0031; spec §5; contratos §3). O relatório nunca mostra a nota.
class ClinicalRecordOpeningsController < ApplicationController
  include Authentication
  include AttendanceAccess
  include ClinicalRecordGate
  include MfaStepUp

  REPORT_LIMIT = 500
  ERROR_STATUS = { missing_role: :forbidden, missing_link: :forbidden, cbo_not_allowed: :forbidden,
                   patient_not_found: :not_found, invalid_reason: :unprocessable_entity }.freeze
  DATE = /\A\d{4}-\d{2}-\d{2}\z/

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

  def index
    from, to = period
    return render(json: { error: "invalid_period" }, status: :unprocessable_entity) if from == :invalid || to == :invalid

    scope = ClinicalRecordOpening.includes(:patient, user: :professional).order(created_at: :desc, id: :desc).limit(REPORT_LIMIT)
    scope = scope.where(created_at: from..) if from
    scope = scope.where(created_at: ..to) if to
    scope = scope.where(user_id: params[:user_id]) if params[:user_id].is_a?(String) && params[:user_id].present?
    render json: { items: scope.map { |o| item(o) } }
  end

  private

  def require_report_role
    forbid("missing_role") unless CitizenVerificationPolicy.new(Current.user, nil).manage?
  end

  # from/to "AAAA-MM-DD" no fuso da cidade (Time.zone dentro do request).
  def period
    [ [ :from, :beginning_of_day ], [ :to, :end_of_day ] ].map do |key, edge|
      value = params[key]
      next nil if value.blank?
      next :invalid unless value.is_a?(String) && value.match?(DATE)

      Date.iso8601(value).in_time_zone.public_send(edge)
    rescue Date::Error
      :invalid
    end
  end

  def item(opening)
    { id: opening.id, user_name: Screenings::Json.staff_name(opening.user), cpf_masked: opening.patient.cpf_masked,
      reason_code: opening.reason_code, created_at: opening.created_at.iso8601, expires_at: opening.expires_at.iso8601 }
  end
end
