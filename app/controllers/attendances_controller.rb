# Fila (espera/atendimento), chamada e encerramento do atendimento (spec
# 2026-09-25-citizen-appointments §2, §4).
class AttendancesController < ApplicationController
  include Authentication
  include AttendanceAccess

  ERROR_STATUS = {
    invalid_outcome: :unprocessable_entity, referral_required: :unprocessable_entity,
    invalid_unit: :unprocessable_entity, already_closed: :conflict, already_called: :conflict,
    wrong_unit: :unprocessable_entity, invalid_transition: :unprocessable_entity, queue_empty: :not_found
  }.freeze

  before_action :require_attendance_staff, only: %i[queue close]
  before_action :require_professional, only: %i[call call_next]

  def queue
    unit = HealthUnit.find_by(id: params[:id])
    return render json: { error: "not_found" }, status: :not_found unless unit

    render json: { waiting: Attendances::UnitQueue.waiting(unit.id).map { |a| queue_json(a) },
                   in_care: Attendances::UnitQueue.in_care(unit.id).map { |a| queue_json(a) } }
  end

  def call
    attendance = Attendance.find_by(id: params[:id])
    return render json: { error: "not_found" }, status: :not_found unless attendance

    result = Attendances::Call.call(attendance: attendance, health_unit_id: params[:health_unit_id], by: Current.user)
    return render_failure(result, ERROR_STATUS) if result.failure?

    render json: { attendance: attendance_json(result.payload[:attendance]) }
  end

  def call_next
    result = Attendances::CallNext.call(health_unit_id: params[:id], by: Current.user)
    return render_failure(result, ERROR_STATUS) if result.failure?

    render json: { attendance: attendance_json(result.payload[:attendance]) }
  end

  def close
    attendance = Attendance.find_by(id: params[:id])
    return render json: { error: "not_found" }, status: :not_found unless attendance
    return forbid unless params[:outcome].to_s == "left" || CitizenVerificationPolicy.new(Current.user, nil).care?

    result = Attendances::Close.call(attendance: attendance, outcome: params[:outcome],
                                     referral_unit_id: params[:referral_unit_id],
                                     referral_note: params[:referral_note], by: Current.user)
    return render_failure(result, ERROR_STATUS) if result.failure?

    render json: { attendance: attendance_json(result.payload[:attendance]),
                   appointment_request: request_json(result.payload[:appointment_request]) }
  end

  private

  def queue_json(a)
    {
      id: a.id, cpf_masked: a.citizen.cpf_masked, checked_in_at: a.checked_in_at&.iso8601,
      protocol_name: a.root_triage&.protocol_name, priority: a.priority,
      source: a.appointment_id ? "appointment" : "triage", appointment_time: a.appointment&.scheduled_at&.iso8601,
      called_at: a.called_at&.iso8601, called_by_name: a.called_by_user&.email_address
    }
  end

  def attendance_json(a)
    {
      id: a.id, triage_id: a.triage_id, appointment_id: a.appointment_id, health_unit_id: a.health_unit_id,
      unit_name: a.health_unit.name, status: a.status, checked_in_at: a.checked_in_at&.iso8601,
      check_in_method: a.check_in_method, called_at: a.called_at&.iso8601, outcome: a.outcome,
      referral_unit_name: a.referral_unit&.name, referral_note: a.referral_note, closed_at: a.closed_at&.iso8601
    }
  end

  def request_json(r)
    return nil unless r

    { id: r.id, kind: r.kind, target_unit_name: r.target_unit.name, status: r.status }
  end
end
