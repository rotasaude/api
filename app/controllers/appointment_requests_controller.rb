# Pedidos de agendamento e agenda do dia da unidade (spec 2026-09-25 §4).
class AppointmentRequestsController < ApplicationController
  include Authentication
  include AttendanceAccess

  ERROR_STATUS = {
    invalid_time: :unprocessable_entity, request_not_open: :conflict, wrong_unit: :unprocessable_entity,
    invalid_unit: :unprocessable_entity, reason_too_short: :unprocessable_entity
  }.freeze

  before_action :require_verifier

  def index
    unit = HealthUnit.find_by(id: params[:id])
    return render json: { error: "not_found" }, status: :not_found unless unit

    requests = AppointmentRequest.where(target_unit: unit, status: "open")
                                 .includes(:citizen, :origin_unit, :root_triage).to_a
                                 .sort_by { |r| [ r.root_triage.priority || 999, r.created_at ] }
    render json: { requests: requests.map { |r| request_json(r) } }
  end

  def schedule
    request = AppointmentRequest.find_by(id: params[:id])
    return render json: { error: "not_found" }, status: :not_found unless request

    result = Appointments::Schedule.call(request: request, scheduled_at: params[:scheduled_at],
                                         health_unit_id: params[:health_unit_id], by: Current.user)
    return render_failure(result, ERROR_STATUS) if result.failure?

    render json: { appointment: appointment_json(result.payload[:appointment]) }, status: :created
  end

  def dismiss
    request = AppointmentRequest.find_by(id: params[:id])
    return render json: { error: "not_found" }, status: :not_found unless request

    result = AppointmentRequests::Dismiss.call(request: request, reason: params[:reason],
                                               health_unit_id: params[:health_unit_id], by: Current.user)
    return render_failure(result, ERROR_STATUS) if result.failure?

    render json: { request: { id: request.id, status: request.status } }
  end

  def agenda
    unit = HealthUnit.find_by(id: params[:id])
    return render json: { error: "not_found" }, status: :not_found unless unit

    day = (Date.iso8601(params[:date].to_s) rescue Time.zone.today)
    appointments = Appointment.where(health_unit: unit, scheduled_at: day.in_time_zone.all_day)
                              .includes(:citizen, :request).order(:scheduled_at)
    render json: { appointments: appointments.map { |a| agenda_json(a) } }
  end

  private

  def request_json(r)
    {
      id: r.id, kind: r.kind, origin_unit_name: r.origin_unit.name, created_at: r.created_at.iso8601,
      cpf_masked: r.citizen.cpf_masked, priority: r.root_triage.priority, note: r.note,
      reopened_reason: r.reopened_reason
    }
  end

  def appointment_json(a)
    { id: a.id, scheduled_at: a.scheduled_at.iso8601, status: a.status,
      confirmation_deadline_at: a.confirmation_deadline_at&.iso8601 }
  end

  def agenda_json(a)
    { id: a.id, scheduled_at: a.scheduled_at.iso8601, cpf_masked: a.citizen.cpf_masked, kind: a.request.kind,
      status: a.status }
  end
end
