# Andamento da notificação (módulo 25; contrato §5, K6): possible → notified,
# notified → investigating, investigating → closed (com classificação) e
# closed → entered (com o número oficial). Sob lock da linha:
#   - `version` diferente da gravada → stale_version (409);
#   - destino fora de Catalog::TRANSITIONS (entered/dismissed travam) →
#     invalid_transition;
#   - classificação só em `closed` e número oficial só em `entered`: em outro
#     destino → invalid_request com `field`; faltando ou inválidos →
#     classification_required / official_number_required;
#   - `reason` opcional, ≤ Catalog::REASON_MAX depois do squish (texto longo é
#     recusado, nunca truncado) → invalid_reason com `field: "reason"`.
# Grava o estado, closed_at/entered_at (e o notificador em possible →
# notified), o evento imutável (status, classificação, autor, motivo cifrado),
# `version += 1` e publica `disease_notification.transitioned` só com ids.
# Motivo, classificação e número oficial nunca em evento, log, erro nem Result.
module Surveillance
  module Transition
    module_function

    # -> Result.ok(notification:) | fail(:stale_version | :invalid_transition | :invalid_request |
    # :classification_required | :official_number_required | :invalid_reason).
    def call(notification:, to:, version:, by:, classification: nil, official_number: nil, reason: nil)
      raise ArgumentError, "by required" if by.nil?

      ApplicationRecord.transaction do
        locked = DiseaseNotification.lock.find(notification.id)
        next Result.fail(:stale_version) unless locked.version == version
        next Result.fail(:invalid_transition) unless Catalog::TRANSITIONS.fetch(locked.status, []).include?(to)

        checked = check(to: to, classification: classification, official_number: official_number, reason: reason)
        next checked if checked.failure?

        apply(locked, to: to, by: by, reason: checked.payload.fetch(:reason), classification: classification,
                      official_number: official_number)
        DomainEvents.publish("disease_notification.transitioned", notification_id: locked.id, user_id: by.id)
        Result.ok(notification: locked)
      end
    end

    def check(to:, classification:, official_number:, reason:)
      return Result.fail(:invalid_request, details: { field: "classification" }) if to != "closed" && !classification.nil?
      return Result.fail(:invalid_request, details: { field: "official_number" }) if to != "entered" && !official_number.nil?
      return Result.fail(:classification_required) if to == "closed" && !Catalog::CLASSIFICATIONS.include?(classification)
      return Result.fail(:official_number_required) if to == "entered" && !valid_number?(official_number)

      text = nil
      unless reason.nil?
        return invalid_reason unless reason.is_a?(String)

        text = reason.squish.presence
        return invalid_reason if text && text.length > Catalog::REASON_MAX
      end
      Result.ok(reason: text)
    end

    def apply(locked, to:, by:, reason:, classification:, official_number:)
      now = Time.current
      changes = { status: to, version: locked.version + 1 }
      case to
      when "notified" then changes[:notifier_user_id] = by.id
      when "closed" then changes.merge!(classification: classification, closed_at: now)
      when "entered" then changes.merge!(official_number: official_number, entered_at: now)
      end
      locked.update!(changes)
      DiseaseNotificationEvent.create!(notification: locked, status: to, by_user: by, reason: reason,
                                       classification: to == "closed" ? classification : nil)
    end

    def valid_number?(value) = value.is_a?(String) && value.match?(Catalog::OFFICIAL_NUMBER)
    def invalid_reason = Result.fail(:invalid_reason, details: { field: "reason" })
    private_class_method :check, :apply, :valid_number?, :invalid_reason
  end
end
