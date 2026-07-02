# E-mail de redefinição de senha (F-06.2, ADR-0022). Link aponta para o
# frontend (PUBLIC_DASHBOARD_URL); o token expira em 15 min e é de uso único.
class PasswordMailer < ApplicationMailer
  def reset(user)
    @user = user
    token = user.generate_token_for(:password_reset)
    base = ENV["PUBLIC_DASHBOARD_URL"] || "http://localhost:5174/dashboard/"
    @reset_url = "#{base}?reset=#{token}"
    mail(to: user.email_address, subject: "[rota-saúde] Redefinição de senha")
  end
end
