# Endpoints de autoria/preview de protocolos. Ver ADR-0016 e ADR-0017.
# A UI de autoria (apps/web/src/protocols) consome estes endpoints.
class ProtocolsController < ApplicationController
  before_action :authenticate_author!

  # GET /protocols/:name — definição ativa
  def show
    protocol = Protocols.current(name: params[:name], municipality: current_author.municipality)
    render json: protocol.to_h
  rescue Protocols::NotFound
    head :not_found
  end

  # POST /protocols/:name/preview — workflow: simula resposta + retorna outcome
  def preview
    protocol = Protocols.current(name: params[:name], municipality: current_author.municipality)
    answers = params.require(:answers).to_unsafe_h
    outcome = protocol.evaluate(answers)
    render json: outcome.to_h
  rescue Protocols::NotFound
    head :not_found
  end

  # POST /protocols/:name/gate — valida uma definição candidata (linter + schema)
  def gate
    definition = params.require(:definition).to_unsafe_h
    result = Protocols::Validator.call(definition)

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
end
