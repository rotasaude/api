require "rails_helper"

RSpec.describe "Evento → consumer com cidade (ADR-0004 e ADR-0003)", type: :job do
  include ActiveJob::TestHelper

  after do
    DomainEvents.registry["smoke.test"]&.clear
  end

  it "publish dentro de uma cidade → consumer roda dentro da MESMA cidade" do
    city = create(:city, slug: TEST_CITY_A.slug, status: "active",
                         database_url: city_database_url("rota_saude_test_city_a"))

    klass = Class.new(ApplicationJob) do
      include IdempotentConsumer
      class << self; attr_accessor :seen_tenant; end
      def handle(**)
        self.class.seen_tenant = Current.city&.slug
      end
    end
    stub_const("SeenTenantJob", klass)
    DomainEvents.bind("smoke.test", to: SeenTenantJob)

    Current.city = city

    perform_enqueued_jobs do
      DomainEvents.publish("smoke.test")
    end

    # Ported (5c-3): the consumer's IdempotentConsumer#with_city looks the city
    # up by slug (City.find_by(slug:)) and sets Current.city to it — proving
    # the consumer actually ran scoped to the city the event was published in,
    # not merely that some value happened to match.
    expect(SeenTenantJob.seen_tenant).to eq(TEST_CITY_A.slug)
  end
end
