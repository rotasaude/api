# Ponto único de autenticação (ADR-0011). Strategies isoladas; seam para
# gov.br entrar sem reescrever sessão.
#
# Estratégias disponíveis:
#   - password(email:, password:) — Rails has_secure_password
# gov.br: Authenticator::GovBr, chamado pelo callback único em auth.* (Plano 3B).
module Authenticator
  def self.password(email:, password:)
    return nil if email.blank? || password.blank?
    user = User.where("lower(email_address) = ?", email.to_s.downcase).first
    return nil unless user&.active?
    return nil unless user.authenticate(password)
    user
  end
end
