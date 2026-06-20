# Ponto único de autenticação (ADR-0022). Strategies isoladas; seam para
# gov.br entrar sem reescrever sessão.
module Authenticator
  def self.password(email:, password:)
    return nil if email.blank? || password.blank?
    user = User.where("lower(email_address) = ?", email.to_s.downcase).first
    return nil unless user&.active?
    return nil unless user.authenticate(password)
    user
  end
end
