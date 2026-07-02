require "rails_helper"
require Rails.root.join("spec/support/admin_rls")

RSpec.describe RecordConsentRevocationJob, type: :job do
  self.use_transactional_tests = false
  before { clean_admin_tables }
  after  { clean_admin_tables }

  def event_args(municipality_id, event_id: SecureRandom.uuid)
    { event_id: event_id, event_name: "consent.revoked", municipality_id: municipality_id,
      payload: { "conversation_id" => SecureRandom.uuid, "consent_id" => SecureRandom.uuid, "reason" => "revogar" } }
  end

  it "bumps the consents_revoked/total metric for the day" do
    muni_id = as_admin { Municipality.create!(name: "Metric City", slug: "metric-city", ibge_code: "3500060").id }
    described_class.new.perform(**event_args(muni_id))
    metric = as_admin do
      DashboardMetric.find_by(municipality_id: muni_id, dimension: "consents_revoked", key: "total")
    end
    expect(metric).to be_present
    expect(metric.value).to eq(1)
  end

  it "does not double-count a re-delivered event (ProcessedEvent dedup)" do
    muni_id = as_admin { Municipality.create!(name: "Metric City 2", slug: "metric-city-2", ibge_code: "3500061").id }
    args = event_args(muni_id)
    described_class.new.perform(**args)
    described_class.new.perform(**args) # same event_id
    metric = as_admin { DashboardMetric.find_by(municipality_id: muni_id, dimension: "consents_revoked", key: "total") }
    expect(metric.value).to eq(1)
  end
end
