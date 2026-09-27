# Vínculo do profissional com a unidade (ADR 0021; spec §4.1). Abrir e
# encerrar exigem municipal_admin e step-up: o vínculo é a metade da
# autorização clínica que faltava ao papel (D5).
class ProfessionalLinksController < ApplicationController
  include Authentication
  include AttendanceAccess
  include MfaStepUp
  include ProfessionalRendering

  wrap_parameters false

  ERROR_STATUS = {
    invalid_cbo: :unprocessable_entity, council_mismatch: :unprocessable_entity, invalid_unit: :unprocessable_entity,
    already_linked: :conflict, already_ended: :conflict
  }.freeze

  before_action :require_admin

  def create
    professional = Professional.find_by(id: params[:id])
    return render(json: { error: "not_found" }, status: :not_found) unless professional
    return require_step_up! unless reauthenticated_recently?

    body = scalar_body(%w[health_unit_id cbo_code])
    result = Professionals::OpenLink.call(professional: professional, health_unit_id: body["health_unit_id"],
                                          cbo_code: body["cbo_code"], by: Current.user)
    return render_failure(result, ERROR_STATUS) if result.failure?

    render json: { link: link_json(result.payload[:link]) }, status: :created
  end

  def end_link
    link = ProfessionalLink.find_by(id: params[:id])
    return render(json: { error: "not_found" }, status: :not_found) unless link
    return require_step_up! unless reauthenticated_recently?

    result = Professionals::EndLink.call(link: link, by: Current.user)
    return render_failure(result, ERROR_STATUS) if result.failure?

    render json: { link: link_json(result.payload[:link]), cancelled_shift_ids: result.payload[:cancelled_shift_ids] }
  end
end
