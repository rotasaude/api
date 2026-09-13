require "rails_helper"

RSpec.describe "Evento → consumer com tenant (ADR-0004 e ADR-0003)", type: :job do
  include ActiveJob::TestHelper

  before do
    Current.reset
  end

  after do
    Current.reset
    DomainEvents.registry["smoke.test"]&.clear
  end

  it "publish dentro de tenant → consumer roda dentro do mesmo tenant" do
    klass = Class.new(ApplicationJob) do
      include IdempotentConsumer
      class << self; attr_accessor :seen_tenant; end
      def handle(**)
        self.class.seen_tenant = ApplicationRecord.connection.select_value("SELECT current_setting('app.municipality_id')")
      end
    end
    stub_const("SeenTenantJob", klass)
    DomainEvents.bind("smoke.test", to: SeenTenantJob)

    perform_enqueued_jobs do
      ApplicationRecord.transaction do
        Current.municipality_id = @muni_id
        ApplicationRecord.connection.execute(
          ApplicationRecord.sanitize_sql(["SET LOCAL app.municipality_id = ?", @muni_id])
        )
        DomainEvents.publish("smoke.test")
      end
    end

    # Not ported yet (5c-3): @muni_id is no longer assigned, so the old
    # `eq(@muni_id)` would pass vacuously as eq(nil). The consumer must see the
    # city it was published in; this fails until the spec is ported to city_slug.
    expect(SeenTenantJob.seen_tenant).to eq(TEST_CITY_A.slug)
  end
end
