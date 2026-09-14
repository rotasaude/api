# CurrentAttributes resetado por request e por job (ver ADR-0003).
class Current < ActiveSupport::CurrentAttributes
  attribute :session
  # Cidade resolvida pelo host. Serve para log e para o envelope de resposta.
  # NUNCA use em WHERE: o escopo é a conexão, não um valor de coluna.
  attribute :city
  # Sessão de operador JÁ verificada por TOTP, no console de plataforma (admin.*).
  # Nunca coexiste com uma cidade resolvida: o console não resolve cidade.
  attribute :operator_session

  delegate :user, to: :session, allow_nil: true
end
