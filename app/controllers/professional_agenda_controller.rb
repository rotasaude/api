# GET /professionals/me/agenda?from=&to= (ADR 0029 §7; contratos §3, §9): até 7
# dias, inclusivos; o papel health_professional e o cadastro profissional.
class ProfessionalAgendaController < ApplicationController
  include Authentication
  include AttendanceAccess

  MAX_DAYS = 7

  before_action :require_professional

  def show
    professional = Current.user.professional
    return render(json: { error: "no_profile" }, status: :not_found) unless professional

    range = Scheduling::DateRange.parse(params[:from], params[:to], default_days: MAX_DAYS, max_days: MAX_DAYS)
    return render(json: { error: "invalid_range" }, status: :unprocessable_entity) unless range

    render json: Scheduling::ProfessionalAgenda.call(professional: professional, from: range.begin, to: range.end)
  end
end
