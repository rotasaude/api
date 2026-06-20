# Publisher de eventos de domínio (ADR-0003 + emenda ADR-0020).
#   DomainEvents.publish("triagem.completed", triagem_id: t.id, tier: :alta)
# Não chame fora de uma transação aberta (ADR-0004 garante COMMIT antes do enqueue).
module DomainEvents
  class TenantMissing < StandardError; end
  class UnknownBindingError < StandardError; end

  Subscriber = Struct.new(:job, :queue, keyword_init: true)

  class << self
    def registry
      @registry ||= Hash.new { |h, k| h[k] = [] }
    end

    def bind(event_name, to:, queue: nil)
      # Touch the key so audit-only events (to: []) still appear in registry.keys.
      registry[event_name.to_s]
      Array(to).each { |job| registry[event_name.to_s] << Subscriber.new(job: job.to_s, queue: queue) }
    end

    def publish(event_name, **payload)
      event_id        = SecureRandom.uuid
      municipality_id = Current.municipality_id
      raise TenantMissing, "publish #{event_name} sem tenant setado" if municipality_id.nil?

      DomainEvent.create!(
        id: event_id,
        name: event_name.to_s,
        payload: payload,
        municipality_id: municipality_id,
        occurred_at: Time.current
      )

      registry[event_name.to_s].each do |sub|
        klass = sub.job.constantize
        target = sub.queue ? klass.set(queue: sub.queue) : klass
        target.perform_later(
          event_id: event_id,
          event_name: event_name.to_s,
          municipality_id: municipality_id,
          payload: payload.deep_stringify_keys
        )
      end

      event_id
    end
  end
end
