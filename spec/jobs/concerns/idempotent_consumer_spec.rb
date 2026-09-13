require "rails_helper"

RSpec.describe IdempotentConsumer do
  let!(:city) { create(:city, database_url: city_database_url("rota_saude_test_city_a")) }
  let(:consumer_class) do
    Class.new(ApplicationJob) do
      include IdempotentConsumer
      class << self; attr_accessor :handled; end
      def handle(**kwargs)
        self.class.handled = kwargs
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
  end

  it "sem city_slug levanta CityMissing antes do create" do
    expect {
      consumer_class.new.perform(event_id: event_id, event_name: "foo.bar", city_slug: nil, payload: {})
    }.to raise_error(CityScopedJob::CityMissing)
  end
end
