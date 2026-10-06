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
    already_linked: :conflict, already_ended: :conflict,
    type_not_served: :unprocessable_entity, inactive_type: :unprocessable_entity
  }.freeze

  before_action :require_admin

  def create
    professional = Professional.find_by(id: params[:id])
    return render(json: { error: "not_found" }, status: :not_found) unless professional
    return require_step_up! unless reauthenticated_recently?

    body = scalar_body(%w[health_unit_id cbo_code])
    return render(json: { error: "invalid" }, status: :unprocessable_entity) if body.value?(:non_scalar)

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

  # Tipo padrão do vínculo (ADR 0029 §3.2), sem step-up: não muda autorização
  # clínica. Contrato §9: devolve o vínculo puro, sem envelope.
  def default_type
    link = ProfessionalLink.find_by(id: params[:id])
    return render(json: { error: "not_found" }, status: :not_found) unless link

    body = scalar_body(%w[appointment_type_key])
    return render(json: { error: "invalid" }, status: :unprocessable_entity) if body.value?(:non_scalar)

    result = Professionals::SetLinkDefaultType.call(link: link, appointment_type_key: body["appointment_type_key"],
                                                    by: Current.user)
    return render_failure(result, ERROR_STATUS) if result.failure?

    render json: link_json(result.payload[:link])
  end
end
