# Mensagem recebida via webhook. Persistida ANTES de qualquer parse de domínio.
# Ver ADR-0010 (webhook) e ADR-0011 (encryption).
class InboundMessage < ApplicationRecord
  encrypts :raw

  validates :message_id, presence: true, uniqueness: true
  validates :from, :kind, presence: true
end
