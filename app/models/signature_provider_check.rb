# Última checagem de cada PSC (plataforma; ADR 0032). Escrita por toda chamada
# ao PSC; uma falha aqui nunca derruba a assinatura (savepoint: uma recusa do
# banco não envenena a transação de plataforma de quem chamou).
class SignatureProviderCheck < PlatformRecord
  def self.record!(provider, ok:, at: Time.current)
    transaction(requires_new: true) do
      upsert({ provider: provider.to_s, last_check_at: at, last_check_ok: ok }, unique_by: :provider)
    end
  rescue ActiveRecord::ActiveRecordError => e
    Rails.logger.warn("[signature_provider_check] #{e.class}")
    nil
  end
end
