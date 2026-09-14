require "rails_helper"

# Task 5a fix round 1, achado #1: with_city precisa abrir a MESMA garantia
# transacional que o antigo with_tenant abria. Sem isso, o dedup row
# (ProcessedEvent) comita ANTES de #handle rodar; se #handle levanta, o
# retry encontra o ProcessedEvent já lá e pula — exactly-once vira
# at-most-once (e um triage.urgent que falha na entrega nunca seria
# reentregue). Esta é a prova de que a regressão está fechada.
RSpec.describe "IdempotentConsumer transaction parity" do
  let(:city) { create(:city, database_url: city_database_url("rota_saude_test_city_a")) }
  let(:event_id) { SecureRandom.uuid }
  let(:attempts) { { count: 0 } }

  let(:consumer_class) do
    attempts_ref = attempts
    klass = Class.new(ApplicationJob) do
      include IdempotentConsumer

      define_method(:handle) do |**_payload|
        attempts_ref[:count] += 1
        raise "boom (simulated handle failure)" if attempts_ref[:count] == 1
      end
    end
    # ProcessedEvent validates :consumer presence, and IdempotentConsumer sets
    # it to self.class.name — nil for an anonymous class. stub_const gives it
    # a real name, same trick the pre-existing (pre-lot-5a) spec used.
    stub_const("TestIdempotentConsumerTransactionJob", klass)
  end

  def processed_event_for(event_id)
    CityConnection.with(city) { ProcessedEvent.find_by(event_id: event_id) }
  end

  it "rolls back the ProcessedEvent row when handle raises, so a retry processes instead of silently skipping" do
    expect {
      consumer_class.new.perform(event_id: event_id, event_name: "foo.bar", city_slug: city.slug, payload: {})
    }.to raise_error(/boom/)

    expect(attempts[:count]).to eq(1)
    expect(processed_event_for(event_id)).to be_nil,
      "expected no ProcessedEvent row after handle raised — the dedup insert must roll back with it"

    # Retry: same event_id. If the first attempt had left the row committed,
    # this second call would hit RecordNotUnique and skip #handle entirely —
    # the event would be lost, not reprocessed.
    expect {
      consumer_class.new.perform(event_id: event_id, event_name: "foo.bar", city_slug: city.slug, payload: {})
    }.not_to raise_error

    expect(attempts[:count]).to eq(2)
    expect(processed_event_for(event_id)).to be_present
  end
end
