# Mensagem recebida via webhook. Persistida ANTES de qualquer parse de domínio.
# Ver ADR-0007 (webhook) e ADR-0013 (encryption).
class InboundMessage < ApplicationRecord
  encrypts :raw
  # Telefone do remetente (api#19): determinístico com a chave da cidade, para
  # a busca por igualdade (Whatsapp::SessionWindow) continuar funcionando.
  # Linhas anteriores: city:encrypt_message_phones.
  encrypts :from, deterministic: true, key_provider: CityDeterministicKeyProvider.new

  validates :message_id, presence: true, uniqueness: true
  validates :from, :kind, presence: true
end
