# Detecta conversations com Consent ativo em versão anterior à atual.
# Não muda estado — apenas reporta. Mudança de estado acontece no próximo
# inbound (ADR-0012).
class ReconcileConsentsJob < ApplicationJob
  include AdminRoleJob
  queue_as :housekeeping

  def perform
    Municipality.find_each do |muni|
      current = Consents.current_version(muni.id)
      stale = Consent.where(municipality_id: muni.id, revoked_at: nil).where.not(version: current).count
      Rails.logger.info("[reconcile_consents] muni=#{muni.id} current=#{current} stale_active=#{stale}")
    end
  end
end
