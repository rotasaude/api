# Recusar sugestão com motivo (contrato §4): 1..500, recusado se longo
# (nunca cortado), cifrado. O cidadão nunca vê.
module CareLines
  module DismissSuggestion
    module_function

    def call(suggestion:, reason:, by:)
      text = reason.is_a?(String) ? reason.strip : ""
      return Result.fail(:reason_required, details: { field: "reason" }) if text.empty?
      return Result.fail(:too_long, details: { field: "reason" }) if text.length > Catalog::TEXT_MAX

      ApplicationRecord.transaction do
        suggestion.lock!
        next Result.fail(:invalid_transition) unless suggestion.pending?

        suggestion.update!(status: "dismissed", decided_by_user: by, decided_at: Time.current, dismiss_reason: text)
        DomainEvents.publish("care_line_suggestion.dismissed", care_line_suggestion_id: suggestion.id, user_id: by.id)
        Result.ok(suggestion: suggestion)
      end
    end
  end
end
