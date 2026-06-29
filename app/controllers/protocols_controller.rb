# Endpoints de autoria/preview de protocolos. Ver ADR-0016 e ADR-0017.
# A UI de autoria (apps/web/src/protocols) consome estes endpoints.
class ProtocolsController < ApplicationController
  # show/preview leem ProtocolDefinition sob RLS → precisam de within_tenant.
  # gate só valida estrutura, sem hit no DB → pula.
  skip_tenant_scope only: :gate

  before_action :authenticate_author!

  # GET /protocols/:name — definição ativa
  def show
    protocol = Protocols.current(current_author.municipality_id, name: params[:name])
    render json: protocol.to_h
  rescue Protocols::NotFound
    head :not_found
  end

  # POST /protocols/:name/preview — workflow: simula resposta + retorna outcome
  def preview
    protocol = Protocols.current(current_author.municipality_id, name: params[:name])
    answers = params.require(:answers).to_unsafe_h
    outcome = protocol.evaluate(answers)
    render json: outcome.to_h
  rescue Protocols::NotFound
    head :not_found
  end

  # POST /protocols/:name/gate — valida uma definição candidata (gate completo)
  def gate
    definition = params.require(:definition).to_unsafe_h
    result = Protocols::Gate.call(definition)

    if result.valid?
      render json: { valid: true }
    else
      render json: { valid: false, errors: result.errors }, status: :unprocessable_entity
    end
  end

  private

  def authenticate_author!
    # Stub — autenticação real vira ADR próprio. Por enquanto barra acesso anônimo.
    head :unauthorized unless request.headers["Authorization"].present?
  end

  def current_author
    @current_author ||= Author.find_by(token: request.headers["Authorization"].to_s.split.last)
  end

  # Override do TenantScopedRequest: tenant deste request é a cidade do author.
  # Sem author/sem muni: within_tenant levanta TenantMissing (falha fechada).
  def current_municipality
    current_author&.municipality
  end
end
