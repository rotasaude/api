# Pedidos de agendamento e agenda do dia da unidade (spec 2026-09-25 §4).
class AppointmentRequestsController < ApplicationController
  include Authentication
  include AttendanceAccess

  ERROR_STATUS = {
    invalid_time: :unprocessable_entity, request_not_open: :conflict, wrong_unit: :unprocessable_entity,
    invalid_unit: :unprocessable_entity, reason_too_short: :unprocessable_entity, slot_taken: :conflict,
    slot_unavailable: :conflict, citizen_busy: :conflict, fit_in_limit: :conflict, use_slots: :conflict,
    invalid_reason: :unprocessable_entity, type_not_served: :unprocessable_entity, outside_shift: :unprocessable_entity,
    invalid_kind: :unprocessable_entity
  }.freeze
  AVAILABILITY_MAX_DAYS = 14
  AVAILABILITY_DEFAULT_DAYS = 7

  before_action :require_verifier

  def index
    unit = HealthUnit.find_by(id: params[:id])
    return render json: { error: "not_found" }, status: :not_found unless unit

    requests = AppointmentRequest.where(target_unit: unit, status: "open")
                                 .includes(:citizen, :origin_unit, :root_triage).to_a
                                 .sort_by { |r| [ r.root_triage.priority || 999, r.created_at ] }
    render json: { requests: requests.map { |r| request_json(r) } }
  end

  # Contratos §4.3, §9: vaga, encaixe ou livre. `appointment_request` (nunca
  # `request`, que é o pedido HTTP do Rails).
  def schedule
    appointment_request = AppointmentRequest.find_by(id: params[:id])
    return render json: { error: "not_found" }, status: :not_found unless appointment_request

    result = book(appointment_request, request.request_parameters)
    return render_failure(result, ERROR_STATUS) if result.failure?

    appointment = Appointment.includes(:citizen, :professional, shift: %i[professional_link schedule_template])
                             .find(result.payload[:appointment].id)
    render json: { appointment: presenter.call(appointment)
                                         .merge(confirmation_deadline_at: appointment.confirmation_deadline_at&.iso8601) },
           status: :created
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
    render json: Scheduling::UnitAgenda.call(unit: unit, date: day)
  end

  # Vagas da unidade e dias de marcação livre (contratos §4.2, §10). Tipo
  # inexistente ou desativado: 200 sem vagas e sem dias legacy.
  def availability
    unit = HealthUnit.find_by(id: params[:id])
    return render json: { error: "not_found" }, status: :not_found unless unit

    range = Scheduling::DateRange.parse(params[:from], params[:to], default_days: AVAILABILITY_DEFAULT_DAYS,
                                                                    max_days: AVAILABILITY_MAX_DAYS)
    return render json: { error: "invalid_range" }, status: :unprocessable_entity unless range

    type = AppointmentType.find_by(key: params[:type].to_s, active: true)
    return render json: { slots: [], legacy_days: [] } unless type

    slots = Scheduling::Availability.for(unit: unit, from: range.begin, to: range.end, appointment_type: type)
    names = Professional.where(id: slots.map(&:professional_id).uniq).pluck(:id, :professional_name).to_h
    render json: {
      slots: slots.map do |s|
        { professional_id: s.professional_id, professional_name: names[s.professional_id], shift_id: s.shift_id,
          starts_at: s.starts_at.iso8601, ends_at: s.ends_at.iso8601 }
      end,
      legacy_days: Scheduling::Transition.legacy_days(unit.id, range.begin, range.end).map(&:iso8601)
    }
  end

  private

  # origin_unit_name é nulo no pedido da triagem (contratos §9).
  def request_json(r)
    {
      id: r.id, kind: r.kind, origin_unit_name: r.origin_unit&.name, created_at: r.created_at.iso8601,
      cpf_masked: r.citizen.cpf_masked, priority: r.root_triage.priority, note: r.note,
      reopened_reason: r.reopened_reason
    }
  end

  # Contratos §4.3, §9: health_unit_id vai nas três formas; ausência de kind = legacy.
  def book(appointment_request, body)
    kind = body["kind"].presence || "legacy"
    return Result.fail(:invalid_kind) unless Appointment::BOOKING_KINDS.include?(kind)
    if kind == "legacy"
      return Appointments::Schedule.call(request: appointment_request, scheduled_at: body["scheduled_at"],
                                         health_unit_id: body["health_unit_id"], by: Current.user,
                                         allow_overlap: body["allow_overlap"] == true)
    end
    if appointment_request.target_unit_id.nil? || body["health_unit_id"].to_s != appointment_request.target_unit_id
      return Result.fail(:wrong_unit)
    end

    professional = Professional.find_by(id: body["professional_id"].to_s)
    type = AppointmentType.find_by(key: body["appointment_type_key"].to_s)
    if kind == "slot"
      Appointments::Book.call(request: appointment_request, professional: professional, starts_at: body["starts_at"],
                              type: type, by: Current.user)
    else
      Appointments::FitIn.call(request: appointment_request, professional: professional,
                               shift: ProfessionalShift.find_by(id: body["shift_id"].to_s), starts_at: body["starts_at"],
                               type: type, reason: body["reason"], by: Current.user)
    end
  end

  # Quem chega aqui marca (require_verifier): vê a justificativa do encaixe.
  def presenter = @presenter ||= Scheduling::AppointmentPresenter.new(show_reason: true)
end
