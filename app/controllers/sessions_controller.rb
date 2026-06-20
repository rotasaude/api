# Sessões — JSON-only (API). Ver ADR-0022.
#
#   POST   /session   { email_address, password }  → 201 + set-cookie
#   DELETE /session                                 → 204 + clear-cookie
class SessionsController < ApplicationController
  # TODO: reativar quando Phase 4 setar current_municipality
  skip_tenant_scope

  include Authentication

  allow_unauthenticated_access only: %i[create]

  rate_limit to: 10, within: 3.minutes, only: :create,
             with: -> { render json: { error: "too_many_requests" }, status: :too_many_requests }

  def create
    user = User.authenticate_by(email_address: params[:email_address], password: params[:password])
    if user
      start_new_session_for(user)
      render json: serialize(user), status: :created
    else
      render json: { error: "invalid_credentials" }, status: :unauthorized
    end
  end

  def destroy
    terminate_session
    head :no_content
  end

  # GET /session — quem está autenticado agora (útil para a UI inicializar).
  def show
    return head :unauthorized unless current_user
    render json: serialize(current_user)
  end

  private

  def serialize(user)
    {
      id: user.id,
      email_address: user.email_address,
      municipality: user.municipality && {
        id: user.municipality.id,
        name: user.municipality.name,
        uf: user.municipality.uf
      }
    }
  end
end
