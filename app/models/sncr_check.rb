# Última conversa com o SNCR (plataforma; ADR 0034; contrato §8): uma linha
# por alvo (real, simulated). Escrita por toda chamada do Sncr::Client; uma
# falha aqui nunca derruba o pedido de números (savepoint).
class SncrCheck < PlatformRecord
  TARGETS = %w[real simulated].freeze

  def self.record!(target, ok:, at: Time.current)
    return nil unless TARGETS.include?(target.to_s)

    transaction(requires_new: true) do
      upsert({ target: target.to_s, last_check_at: at, last_check_ok: ok }, unique_by: :target)
    end
  rescue ActiveRecord::ActiveRecordError => e
    Rails.logger.warn("[sncr_check] #{e.class}")
    nil
  end

  def self.last(target) = find_by(target: target.to_s)
end
