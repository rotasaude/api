# Configuração do PEC da cidade (ADR 0035; contrato §6): endereço (origem)
# do PEC, para o frame-ancestors, e a chave HMAC dos "sistemas externos",
# cifrada com a chave da cidade. Linha única. Só o maintenance escreve
# (PecExternal::Configure). A chave nunca sai: nem em resposta, nem em log,
# nem em inspect.
class PecSetting < ApplicationRecord
  encrypts :hmac_key

  def self.current = first

  def hmac_key_configured? = hmac_key_updated_at.present?

  def inspect
    "#<PecSetting id=#{id.inspect} pec_origin=#{pec_origin.inspect} hmac_key_configured=#{hmac_key_configured?}>"
  end
end
