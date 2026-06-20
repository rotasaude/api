# Publisher de eventos de domínio. Ver ADR-0003.
#
#   Events.publish("triagem.completed", aggregate: triagem, payload: { tier: :alta })
#
# Não chame fora de uma transação aberta: o ADR-0004 garante que o enfileiramento
# só acontece após o COMMIT — se a transação der rollback, o evento e os
# consumidores somem juntos.
module Events
  class UnknownBindingError < StandardError; end

  class << self
    # event_name (String) => [JobClass, ...]
    def bindings
      @bindings ||= Hash.new { |h, k| h[k] = [] }
    end

    def bind(event_name, to:)
      Array(to).each { |job| bindings[event_name.to_s] << job }
    end

    def publish(name, aggregate:, payload: {})
      event = DomainEvent.create!(
        name: name.to_s,
        aggregate_type: aggregate.class.name,
        aggregate_id: aggregate.id.to_s,
        payload: payload,
        occurred_at: Time.current
      )

      dispatch(event)
      event
    end

    # Reenfileira um evento já gravado. Usado pelo script de replay (ADR-0009).
    def redispatch(event)
      dispatch(event)
    end

    private

    def dispatch(event)
      bindings.fetch(event.name) { [] }.each do |job_class|
        job_class.perform_later(event.id)
      end
    end
  end
end
