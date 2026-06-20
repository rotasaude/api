require "rails_helper"

RSpec.describe "Evento → consumer com tenant (ADR-0020)", type: :job do
  include ActiveJob::TestHelper

  self.use_transactional_tests = false

  before do
    Current.reset
    # Create municipality via admin connection (bypass RLS)
    ApplicationRecord.connected_to(role: :admin) do
      conn = ApplicationRecord.connection
      conn.execute("DELETE FROM processed_events")
      conn.execute("DELETE FROM domain_events")
      conn.execute("DELETE FROM municipalities")
      conn.execute(<<~SQL.squish)
        INSERT INTO municipalities (id, name, slug, created_at, updated_at)
        VALUES (gen_random_uuid(), 'Test Municipality', 'test-muni', now(), now())
      SQL
      @muni_id = conn.select_value("SELECT id FROM municipalities WHERE slug='test-muni'")
    end
  end

  after do
    Current.reset
    DomainEvents.registry["smoke.test"]&.clear
    # Clean up test data bypassing RLS (delete in cascade order)
    if @muni_id.present?
      ApplicationRecord.connected_to(role: :admin) do
        conn = ApplicationRecord.connection
        conn.execute("DELETE FROM processed_events WHERE municipality_id = '#{@muni_id}'")
        conn.execute("DELETE FROM domain_events WHERE municipality_id = '#{@muni_id}'")
        conn.execute("DELETE FROM municipalities WHERE id = '#{@muni_id}'")
      end
    end
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
