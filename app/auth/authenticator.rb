# Ponto único de autenticação (ADR-0022). Strategies isoladas; seam para
# gov.br entrar sem reescrever sessão.
#
# Estratégias disponíveis:
#   - password(email:, password:) — Rails has_secure_password
#   - govbr(code:) — OIDC gov.br (RASCUNHO; ver Authenticator::GovBr)
module Authenticator
  def self.password(email:, password:)
    return nil if email.blank? || password.blank?
    user = User.where("lower(email_address) = ?", email.to_s.downcase).first
    return nil unless user&.active?
    return nil unless user.authenticate(password)
    user
  end

  # Delegate para o módulo GovBr. Retorna User ou nil; levanta
  # IntegrationError em falha de rede/token inválido.
  def self.govbr(code:)
    GovBr.authenticate(code: code)
  end
end
