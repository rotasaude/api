# Check-in na unidade (spec 2026-09-24-citizen-attendance-check-in §4, §6):
# caminho normal por código, exceção por CPF. O CPF nunca vai na URL.
class CheckInsController < ApplicationController
  include Authentication
  include AttendanceAccess

  ERROR_STATUS = {
    invalid_cpf: :unprocessable_entity, invalid_code: :unprocessable_entity, code_expired: :unprocessable_entity,
    code_exhausted: :unprocessable_entity, triage_too_old: :unprocessable_entity,
    triage_not_eligible: :unprocessable_entity, invalid_unit: :unprocessable_entity,
    reason_too_short: :unprocessable_entity, already_checked_in: :conflict
  }.freeze

  before_action :require_verifier

  rate_limit to: 30, within: 10.minutes, name: "attendance_check_in",
             by: -> { Current.user&.id || request.remote_ip }, store: AttendanceAccess::RateLimitStore,
             with: -> { render json: { error: "too_many_requests" }, status: :too_many_requests }

  def lookup
    result = Attendances::LookupForCheckIn.call(cpf: params[:cpf], code: params[:code])
    return render_failure(result, ERROR_STATUS) if result.failure?

    citizen = result.payload[:citizen]
    render json: {
      citizen: {
        id: citizen.id, cpf_masked: citizen.cpf_masked, phone_masked: CitizenIdentity::Phone.mask(citizen.phone),
        verification_level: citizen.verification_level
      },
      triage: triage_json(result.payload[:triage])
    }
  end

  def create
    result = Attendances::CheckIn.call(cpf: params[:cpf], code: params[:code], health_unit_id: params[:health_unit_id],
                                       document_checked: params[:document_checked] == true, by: Current.user)
    return render_failure(result, ERROR_STATUS) if result.failure?

    render json: { attendance: attendance_json(result.payload[:attendance]), verified: result.payload[:verified] },
           status: :created
  end

  def search
    result = Attendances::EligibleTriages.call(cpf: params[:cpf])
    return render_failure(result, ERROR_STATUS) if result.failure?

    render json: { triages: result.payload[:triages].map { |t| triage_json(t) } }
  end

  def exception
    result = Attendances::CheckInByException.call(cpf: params[:cpf], triage_id: params[:triage_id],
                                                   health_unit_id: params[:health_unit_id], reason: params[:reason],
                                                   by: Current.user)
    return render_failure(result, ERROR_STATUS) if result.failure?

    render json: { attendance: attendance_json(result.payload[:attendance]) }, status: :created
  end

  private

  def triage_json(t)
    { id: t.id, date: (t.completed_at || t.created_at).iso8601, protocol_name: t.protocol_name, priority: t.priority }
  end

  def attendance_json(a)
    {
      id: a.id, triage_id: a.triage_id, health_unit_id: a.health_unit_id, unit_name: a.health_unit.name,
      status: a.status, checked_in_at: a.checked_in_at&.iso8601, check_in_method: a.check_in_method,
      outcome: a.outcome, referral_unit_name: a.referral_unit&.name, referral_note: a.referral_note,
      closed_at: a.closed_at&.iso8601
    }
  end
end
