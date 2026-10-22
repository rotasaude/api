# Consumidor de citizen_condition.declared (ADR 0040; spec §4).
module CareLines
  class ConditionDeclaredJob < ApplicationJob
    include IdempotentConsumer
    queue_as :default

    def handle(citizen_id:, **)
      return unless Gate.enabled?(Current.city)

      Suggest.for_citizen(citizen_id, today: Time.zone.today)
    end
  end
end
