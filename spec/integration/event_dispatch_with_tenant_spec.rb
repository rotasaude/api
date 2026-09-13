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

    expect(SeenTenantJob.seen_tenant).to eq(@muni_id)
  end
end
