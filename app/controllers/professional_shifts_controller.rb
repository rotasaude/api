# Turnos do profissional (ADR 0021; spec §4.1). Só municipal_admin; sem
# step-up — turno não muda quem pode fazer o quê (D5).
class ProfessionalShiftsController < ApplicationController
  include Authentication
  include AttendanceAccess
  include ProfessionalRendering

  wrap_parameters false

  ERROR_STATUS = {
    invalid_shift: :unprocessable_entity, link_ended: :conflict, shift_overlap: :conflict,
    reason_required: :unprocessable_entity, reason_too_long: :unprocessable_entity, already_cancelled: :conflict
  }.freeze
  DEFAULT_DAYS = 14
  MAX_DAYS = 62

  before_action :require_admin

  def index
    professional = Professional.find_by(id: params[:id])
    return render(json: { error: "not_found" }, status: :not_found) unless professional

    range = requested_range
    return render(json: { error: "invalid_range" }, status: :unprocessable_entity) unless range

    shifts = ProfessionalShift.where(professional: professional)
                              .where("ends_at > ? AND starts_at < ?", range.begin, range.end)
                              .includes(professional_link: :health_unit).order(:starts_at)
    render json: { shifts: shifts.map { |s| shift_json(s) } }
  end

  def create
    link = ProfessionalLink.find_by(id: params[:id])
    return render(json: { error: "not_found" }, status: :not_found) unless link

    body = scalar_body(%w[starts_at ends_at])
    result = Professionals::ScheduleShift.call(link: link, starts_at: body["starts_at"], ends_at: body["ends_at"],
                                               by: Current.user)
    return render_failure(result, ERROR_STATUS) if result.failure?

    render json: { shift: shift_json(result.payload[:shift]) }, status: :created
  end

  def cancel
    shift = ProfessionalShift.find_by(id: params[:id])
    return render(json: { error: "not_found" }, status: :not_found) unless shift

    result = Professionals::CancelShift.call(shift: shift, reason: scalar_body(%w[reason])["reason"], by: Current.user)
    return render_failure(result, ERROR_STATUS) if result.failure?

    render json: { shift: shift_json(result.payload[:shift]) }
  end

  private

  # Dias inteiros no fuso da aplicação; padrão hoje + 14; teto de 62 dias.
  def requested_range
    from = params[:from].present? ? Date.iso8601(params[:from].to_s) : Time.zone.today
    to = params[:to].present? ? Date.iso8601(params[:to].to_s) : from + DEFAULT_DAYS
    return nil if to < from || (to - from) > MAX_DAYS

    from.in_time_zone.beginning_of_day..to.in_time_zone.end_of_day
  rescue ArgumentError, Date::Error
    nil
  end
end
