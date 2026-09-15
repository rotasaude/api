require "rails_helper"

RSpec.describe IdempotentConsumer do
  let!(:city) { create(:city, database_url: city_database_url("rota_saude_test_city_a")) }
  let(:consumer_class) do
    Class.new(ApplicationJob) do
      include IdempotentConsumer
      class << self; attr_accessor :handled, :handle_calls; end
      self.handle_calls = 0
      def handle(**kwargs)
        self.class.handled = kwargs
        self.class.handle_calls += 1
      end
    end
  end
  let(:event_id) { SecureRandom.uuid }

  before do
    stub_const("TestIdempotentConsumer", consumer_class)
  end

  it "executa handle dentro de with_city" do
    consumer_class.new.perform(event_id: event_id, event_name: "foo.bar", city_slug: city.slug, payload: { "x" => 1 })
    expect(consumer_class.handled).to eq(x: 1)
  end

  it "registra ProcessedEvent na cidade" do
    consumer_class.new.perform(event_id: event_id, event_name: "foo.bar", city_slug: city.slug, payload: {})

    row = CityConnection.with(city) { ProcessedEvent.find_by(event_id: event_id, consumer: "TestIdempotentConsumer") }
    expect(row).to be_present
  end

  it "no-op em duplicata" do
    consumer_class.new.perform(event_id: event_id, event_name: "foo.bar", city_slug: city.slug, payload: {})
    expect {
      consumer_class.new.perform(event_id: event_id, event_name: "foo.bar", city_slug: city.slug, payload: {})
    }.not_to raise_error

    # Fix round 1 (M3): "no-op" must mean handle runs exactly once and the
    # dedup row is not duplicated — not merely "does not raise".
    expect(consumer_class.handle_calls).to eq(1)
    rows = CityConnection.with(city) { ProcessedEvent.where(event_id: event_id, consumer: "TestIdempotentConsumer").count }
    expect(rows).to eq(1)
  end

  it "sem city_slug levanta CityMissing antes do create" do
    expect {
      consumer_class.new.perform(event_id: event_id, event_name: "foo.bar", city_slug: nil, payload: {})
    }.to raise_error(CityScopedJob::CityMissing)
  end

  describe "published_at bookkeeping (ResendPendingAlertsJob safety net)" do
    def domain_event_in(city, **attrs)
      CityConnection.with(city) do
        DomainEvent.create!(name: "foo.bar", payload: {}, occurred_at: Time.current, **attrs)
      end
    end

    def reload_domain_event(city, id)
      CityConnection.with(city) { DomainEvent.find(id) }
    end

    it "marca published_at quando handle termina com sucesso" do
      event = domain_event_in(city)

      consumer_class.new.perform(event_id: event.id, event_name: "foo.bar", city_slug: city.slug, payload: {})

      expect(reload_domain_event(city, event.id).published_at).to be_present
    end

    it "deixa published_at nil quando handle levanta" do
      failing_class = Class.new(ApplicationJob) do
        include IdempotentConsumer
        def handle(**) = raise("boom (simulated handle failure)")
      end
      stub_const("FailingIdempotentConsumer", failing_class)
      event = domain_event_in(city)

      expect {
        failing_class.new.perform(event_id: event.id, event_name: "foo.bar", city_slug: city.slug, payload: {})
      }.to raise_error(/boom/)

      expect(reload_domain_event(city, event.id).published_at).to be_nil
    end

    it "marca published_at numa entrega duplicada de um evento ainda não marcado" do
      event = domain_event_in(city)
      # Simula um evento já tratado por este consumer antes deste fix (ProcessedEvent
      # já existe), mas cujo DomainEvent nunca foi marcado published — exatamente o
      # estado que deixava o evento pending para sempre e o ResendPendingAlertsJob
      # tentando redespachar sem parar.
      CityConnection.with(city) do
        ProcessedEvent.create!(event_id: event.id, consumer: "TestIdempotentConsumer", processed_at: Time.current)
      end

      expect {
        consumer_class.new.perform(event_id: event.id, event_name: "foo.bar", city_slug: city.slug, payload: {})
      }.not_to raise_error

      expect(consumer_class.handle_calls).to eq(0)
      expect(reload_domain_event(city, event.id).published_at).to be_present
    end

    it "não sobrescreve um published_at já marcado" do
      event = domain_event_in(city, published_at: 1.hour.ago)
      original = reload_domain_event(city, event.id).published_at

      consumer_class.new.perform(event_id: event.id, event_name: "foo.bar", city_slug: city.slug, payload: {})

      expect(reload_domain_event(city, event.id).published_at).to be_within(1).of(original)
    end

    it "não levanta quando o DomainEvent já foi purgado (event_id sem linha correspondente)" do
      expect {
        consumer_class.new.perform(event_id: SecureRandom.uuid, event_name: "foo.bar", city_slug: city.slug, payload: {})
      }.not_to raise_error
    end

    # M2 (fix round 1): o rescue de RecordNotUnique tem que envolver SÓ o
    # ProcessedEvent.create! do dedup, não o handle. Uma RecordNotUnique que
    # #handle levante por conta própria (ex.: uma constraint de domínio não
    # relacionada ao dedup) não é "já processado" — tem que propagar (e não
    # marcar published), não ser engolida como se fosse uma duplicata normal.
    it "propaga RecordNotUnique levantado dentro de handle — não é a duplicata do ProcessedEvent" do
      raising_class = Class.new(ApplicationJob) do
        include IdempotentConsumer
        def handle(**)
          raise ActiveRecord::RecordNotUnique, "violação de unicidade de domínio, não relacionada ao dedup"
        end
      end
      stub_const("HandleRaisesUniqueViolation", raising_class)
      event = domain_event_in(city)

      expect {
        raising_class.new.perform(event_id: event.id, event_name: "foo.bar", city_slug: city.slug, payload: {})
      }.to raise_error(ActiveRecord::RecordNotUnique, /violação de unicidade de domínio/)

      expect(reload_domain_event(city, event.id).published_at).to be_nil
      # A transação inteira do with_city desfaz — inclusive o próprio dedup
      # row que tinha sido criado com sucesso antes de handle levantar.
      rows = CityConnection.with(city) { ProcessedEvent.where(event_id: event.id).count }
      expect(rows).to eq(0)
    end
  end
end
