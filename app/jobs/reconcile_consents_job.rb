# Detecta conversations com Consent ativo em versão anterior à atual.
# Não muda estado — apenas reporta. Mudança de estado acontece no próximo
# inbound (ADR-0008).
#
# Roda uma vez por cidade (EachCityJob): passada única no banco da cidade, que
# tem um único termo vigente. Current.city só aparece no log, nunca em WHERE.
class ReconcileConsentsJob < ApplicationJob
  prepend EachCityJob
  queue_as :housekeeping

  def perform
    current = Consents.current_version
    stale = Consent.where(revoked_at: nil).where.not(version: current).count
    Rails.logger.info("[reconcile_consents] city=#{Current.city&.slug} current=#{current} stale_active=#{stale}")
  end
end
