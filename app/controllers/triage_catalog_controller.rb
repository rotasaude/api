# Aba "Catálogo de triagens" (ADR 0027; spec 2026-10-05 §6.2; contratos §4.1–
# §4.2). Prefixo próprio: /protocols/:name já captura qualquer segmento.
#   GET /triage_catalog                  — autor, revisor, municipal_admin
#   PUT /triage_catalog/:protocol_name   — municipal_admin + step-up
class TriageCatalogController < ApplicationController
  include Authentication
  include MfaStepUp

  wrap_parameters false

  def index
    return forbid unless policy.read_catalog?

    render json: { offers: Triages::CatalogAdmin.index }
  end

  def update
    return forbid unless policy.manage_catalog?
    return require_step_up! unless reauthenticated_recently?

    result = Triages::SetOffer.call(protocol_name: params[:protocol_name], attributes: body_attributes, by: Current.user)
    if result.failure?
      status = result.reason == :unknown_protocol ? :not_found : :unprocessable_entity
      return render(json: { error: result.reason.to_s }, status: status)
    end

    render json: { offer: Triages::CatalogAdmin.item_for(params[:protocol_name]) }
  end

  private

  def policy = ProtocolPolicy.new(Current.user, nil)

  # Sempre um Hash: corpo malformado vira 422 em SetOffer, nunca 500.
  def body_attributes
    raw = request.request_parameters
    raw.is_a?(Hash) ? raw : {}
  end

  def forbid
    render json: { error: "missing_role" }, status: :forbidden
  end
end
