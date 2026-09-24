# Lista de abertos e encerramento do atendimento (spec
# 2026-09-24-citizen-attendance-check-in §4, §6).
class AttendancesController < ApplicationController
  include Authentication
  include AttendanceAccess

  ERROR_STATUS = {
    invalid_outcome: :unprocessable_entity, referral_required: :unprocessable_entity,
    invalid_unit: :unprocessable_entity, already_closed: :conflict
  }.freeze

  before_action :require_verifier

  def open
    health_unit = HealthUnit.find_by(id: params[:id])
    return render json: { error: "not_found" }, status: :not_found unless health_unit

    attendances = Attendance.open_attendances.where(health_unit: health_unit).includes(:triage, :citizen)
                            .sort_by { |a| [a.triage.priority || 999, a.checked_in_at] }
    render json: { attendances: attendances.map { |a| open_json(a) } }
  end

  def close
    attendance = Attendance.find_by(id: params[:id])
    return render json: { error: "not_found" }, status: :not_found unless attendance

    result = Attendances::Close.call(attendance: attendance, outcome: params[:outcome],
                                     referral_unit_id: params[:referral_unit_id],
                                     referral_note: params[:referral_note], by: Current.user)
    return render_failure(result, ERROR_STATUS) if result.failure?

    render json: { attendance: attendance_json(result.payload[:attendance]) }
  end

  private

  def open_json(a)
    {
      id: a.id, cpf_masked: a.citizen.cpf_masked, checked_in_at: a.checked_in_at&.iso8601,
      protocol_name: a.triage.protocol_name, priority: a.triage.priority
    }
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
