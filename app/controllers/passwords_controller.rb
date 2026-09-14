# Reset de senha por e-mail (F-06.2, ADR-0011). JSON-only, sem autenticação.
# create: sempre 204 (sem enumeração de usuários). update: consome o token de
# uso único e destrói as sessões do usuário.
class PasswordsController < ApplicationController
  include Authentication

  allow_unauthenticated_access only: %i[create update]

  rate_limit to: 10, within: 3.minutes, only: %i[create update],
             with: -> { render json: { error: "too_many_requests" }, status: :too_many_requests }

  # R42: the mail job (ActionMailer::MailDeliveryJob) runs on a worker with no
  # city connection, so it must not carry the User (GlobalID) — everything the
  # e-mail needs is built HERE, inside the city of the request, as plain strings.
  def create
    user = User.where("lower(email_address) = ?", params[:email_address].to_s.downcase).first
    if user&.active?
      token = user.generate_token_for(:password_reset)
      PasswordMailer.reset(email_address: user.email_address, reset_url: password_reset_link(token)).deliver_later
    end
    head :no_content
  end

  def update
    user = User.find_by_token_for(:password_reset, params[:token])
    return render(json: { error: "invalid_token" }, status: :unprocessable_entity) unless user&.active?

    if user.update(password: params[:password], password_confirmation: params[:password_confirmation])
      user.sessions.destroy_all
      head :no_content
    else
      render json: { errors: user.errors.full_messages }, status: :unprocessable_entity
    end
  end

  private

  # Link to the dashboard frontend (separate Vite/static app, not the API host). Per-city destination is Plan 6.
  def password_reset_link(token)
    base = ENV["PUBLIC_DASHBOARD_URL"] || "http://localhost:5175/dashboard/"
    "#{base}?#{{ reset: token }.to_query}"
  end
end
