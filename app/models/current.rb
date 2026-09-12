# CurrentAttributes resetado por request e por job (ver ADR-0003).
class Current < ActiveSupport::CurrentAttributes
  attribute :session
  attribute :municipality_id
  # Cidade resolvida pelo host. Serve para log e para o envelope de resposta.
  # NUNCA use em WHERE: o escopo é a conexão, não um valor de coluna.
  attribute :city

  delegate :user, to: :session, allow_nil: true
end
