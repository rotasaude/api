# Descarte de uma notificação `possible` (módulo 25; contrato §5, K6): a
# equipe da vigilância decide que o achado da rede de segurança não é caso.
# Sob lock da linha: `version` diferente → stale_version (409); fora de
# `possible` → invalid_transition; `reason` obrigatório, 3..500 caracteres
# depois do squish (longo é recusado, nunca truncado) → invalid_reason com
# `field: "reason"`. Grava `dismissed`, dismissed_at, o evento imutável
# (motivo cifrado), `version += 1` e publica `disease_notification.dismissed`
# só com ids. O motivo nunca em evento, log, erro nem Result.
module Surveillance
  module Dismiss
    REASON_RANGE = (3..Catalog::REASON_MAX)

    module_function

    # -> Result.ok(notification:) | fail(:stale_version | :invalid_transition | :invalid_reason).
    def call(notification:, reason:, version:, by:)
      raise ArgumentError, "by required" if by.nil?

      ApplicationRecord.transaction do
        locked = DiseaseNotification.lock.find(notification.id)
        next Result.fail(:stale_version) unless locked.version == version
        next Result.fail(:invalid_transition) unless locked.status == "possible"

        text = reason.is_a?(String) ? reason.squish : nil
        next Result.fail(:invalid_reason, details: { field: "reason" }) unless text && REASON_RANGE.cover?(text.length)

        locked.update!(status: "dismissed", dismissed_at: Time.current, version: locked.version + 1)
        DiseaseNotificationEvent.create!(notification: locked, status: "dismissed", by_user: by, reason: text)
        DomainEvents.publish("disease_notification.dismissed", notification_id: locked.id, user_id: by.id)
        Result.ok(notification: locked)
      end
    end
  end
end
