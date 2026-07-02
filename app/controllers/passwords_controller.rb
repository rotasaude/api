# Reset de senha por e-mail (F-06.2, ADR-0022). JSON-only, sem autenticação.
# create: sempre 204 (sem enumeração de usuários). update: consome o token de
# uso único e destrói as sessões do usuário.
class PasswordsController < ApplicationController
  skip_tenant_scope

  include Authentication

  allow_unauthenticated_access only: %i[create update]

  rate_limit to: 10, within: 3.minutes, only: %i[create update],
             with: -> { render json: { error: "too_many_requests" }, status: :too_many_requests }

  def create
    user = User.where("lower(email_address) = ?", params[:email_address].to_s.downcase).first
    PasswordMailer.reset(user).deliver_later if user&.active?
    head :no_content
  end

  def update
    user = User.find_by_token_for(:password_reset, params[:token])
    return render(json: { error: "invalid_token" }, status: :unprocessable_entity) unless user

    if user.update(password: params[:password], password_confirmation: params[:password_confirmation])
      user.sessions.destroy_all
      head :no_content
    else
      render json: { errors: user.errors.full_messages }, status: :unprocessable_entity
    end
  end
end
