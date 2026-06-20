# Detecta conversations com Consent ativo em versão anterior à atual.
# Não muda estado — apenas reporta. Mudança de estado acontece no próximo
# inbound (ADR-0012).
class ReconcileConsentsJob < ApplicationJob
  include AdminRoleJob
  queue_as :housekeeping

  def perform
    current = Consents.current_version
    stale = Consent.active.where.not(version: current).count
    Rails.logger.info("[reconcile_consents] current_version=#{current} stale_active=#{stale}")
  end
end
