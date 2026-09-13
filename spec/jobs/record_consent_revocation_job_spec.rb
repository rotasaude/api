require "rails_helper"

RSpec.describe RecordConsentRevocationJob, type: :job do
  # Same slug/database_url as TEST_CITY_A so the job's with_city re-enters the
  # shard the harness already has open — DashboardMetric is then readable via
  # the default connection below without a second CityConnection.with.
  let!(:city) do
    create(:city, slug: TEST_CITY_A.slug, status: "active", database_url: city_database_url("rota_saude_test_city_a"))
  end

  def event_args(event_id: SecureRandom.uuid)
    { event_id: event_id, event_name: "consent.revoked", city_slug: city.slug,
      payload: { "conversation_id" => SecureRandom.uuid, "consent_id" => SecureRandom.uuid, "reason" => "revogar" } }
  end

  it "bumps the consents_revoked/total metric for the day" do
    described_class.new.perform(**event_args)
    metric = DashboardMetric.find_by(dimension: "consents_revoked", key: "total")
    expect(metric).to be_present
    expect(metric.value).to eq(1)
  end

  it "does not double-count a re-delivered event (ProcessedEvent dedup)" do
    args = event_args
    described_class.new.perform(**args)
    described_class.new.perform(**args) # same event_id
    metric = DashboardMetric.find_by(dimension: "consents_revoked", key: "total")
    expect(metric.value).to eq(1)
  end
end
