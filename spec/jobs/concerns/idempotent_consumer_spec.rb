require "rails_helper"

RSpec.describe IdempotentConsumer do
  let(:muni) { create(:municipality) }
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
    ApplicationRecord.transaction do
      Current.municipality_id = muni.id
      ApplicationRecord.connection.execute(
        ApplicationRecord.sanitize_sql(["SET LOCAL app.municipality_id = ?", muni.id])
      )
      ApplicationRecord.connection.execute(<<~SQL.squish)
        INSERT INTO domain_events (id, name, payload, municipality_id, occurred_at, created_at, updated_at)
        VALUES ('#{event_id}', 'foo.bar', '{}', '#{muni.id}', now(), now(), now());
      SQL
    end
  end

  after do
    Current.reset
  end

  it "executa handle dentro de with_tenant" do
    consumer_class.new.perform(event_id: event_id, event_name: "foo.bar", municipality_id: muni.id, payload: { "x" => 1 })
    expect(consumer_class.handled).to eq(x: 1)
  end

  it "registra ProcessedEvent com tenant" do
    consumer_class.new.perform(event_id: event_id, event_name: "foo.bar", municipality_id: muni.id, payload: {})
    ApplicationRecord.connected_to(role: :admin) do
      row = ProcessedEvent.find_by(event_id: event_id, consumer: "TestIdempotentConsumer")
      expect(row.municipality_id).to eq(muni.id)
    end
  end

  it "no-op em duplicata" do
    consumer_class.new.perform(event_id: event_id, event_name: "foo.bar", municipality_id: muni.id, payload: {})
    expect {
      consumer_class.new.perform(event_id: event_id, event_name: "foo.bar", municipality_id: muni.id, payload: {})
    }.not_to raise_error
  end

  it "sem municipality_id levanta antes do create" do
    expect {
      consumer_class.new.perform(event_id: event_id, event_name: "foo.bar", municipality_id: nil, payload: {})
    }.to raise_error(TenantScopedJob::TenantMissing)
  end
end
