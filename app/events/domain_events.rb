# Publisher de eventos de domínio (ADR-0004).
#   DomainEvents.publish("triage.completed", triage_id: t.id, tier: :alta)
# Publique dentro da transação da cidade (ADR-0004): o DomainEvent comita junto
# com a escrita de domínio, e os subscribers (ApplicationJob, com
# enqueue_after_transaction_commit — R40) só entram na fila após esse COMMIT;
# em ROLLBACK, nenhum é enfileirado. Fora de transação, enfileiram na hora.
module DomainEvents
  class CityMissing < StandardError; end
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
      event_id  = SecureRandom.uuid
      city_slug = Current.city&.slug
      raise CityMissing, "publish #{event_name} sem cidade setada" if city_slug.nil?

      DomainEvent.create!(
        id: event_id,
        name: event_name.to_s,
        payload: payload,
        occurred_at: Time.current
      )

      registry[event_name.to_s].each do |sub|
        klass = sub.job.constantize
        target = sub.queue ? klass.set(queue: sub.queue) : klass
        target.perform_later(
          event_id: event_id,
          event_name: event_name.to_s,
          city_slug: city_slug,
          payload: payload.deep_stringify_keys
        )
      end

      event_id
    end
  end
end
