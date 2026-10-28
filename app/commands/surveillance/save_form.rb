# Grava a ficha de notificação individual (módulo 25; contrato §5, §14, K6):
# o PATCH manda a ficha inteira, que substitui a anterior. Sob lock da linha:
#   - `version` diferente da gravada → stale_version (409);
#   - situação entered/dismissed (ficha travada) → invalid_transition;
#   - Form.validate recusa → invalid_form com o caminho `form.<chave>`.
# Grava o form normalizado, `version += 1` e publica
# `disease_notification.updated` só com `notification_id`. A ficha é dado de
# saúde: nunca em log, evento, erro nem Result.
module Surveillance
  module SaveForm
    LOCKED_STATUSES = %w[entered dismissed].freeze

    module_function

    # -> Result.ok(notification:) | fail(:stale_version | :invalid_transition | :invalid_form).
    def call(notification:, form:, version:, by:)
      raise ArgumentError, "by required" if by.nil?

      validated = Form.validate(form)
      ApplicationRecord.transaction do
        locked = DiseaseNotification.lock.find(notification.id)
        next Result.fail(:stale_version) unless locked.version == version
        next Result.fail(:invalid_transition) if LOCKED_STATUSES.include?(locked.status)
        next validated if validated.failure?

        locked.update!(form: validated.payload.fetch(:form), version: locked.version + 1)
        DomainEvents.publish("disease_notification.updated", notification_id: locked.id)
        Result.ok(notification: locked)
      end
    end
  end
end
