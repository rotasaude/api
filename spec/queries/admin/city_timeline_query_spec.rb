require "rails_helper"
require Rails.root.join("spec/support/admin_rls")

RSpec.describe Admin::CityTimelineQuery do
  self.use_transactional_tests = false

  before { clean_admin_tables }
  after  { clean_admin_tables }

  it "devolve eventos da cidade em ordem desc, com limit" do
    rows = as_admin do
      m = Municipality.create!(name: "Alpha", slug: "alpha", status: "active")
      DomainEvent.create!(municipality_id: m.id, name: "triage.started", payload: {}, occurred_at: 2.hours.ago)
      DomainEvent.create!(municipality_id: m.id, name: "triage.completed", payload: { "tier" => "red" }, occurred_at: 1.hour.ago)
      Admin::CityTimelineQuery.call(municipality: m, limit: 50)
    end

    expect(rows.map { |r| r[:type] }).to eq(%w[triage.completed triage.started])
    expect(rows.first[:at]).to be_present
    expect(rows.first[:summary]).to be_a(String)
  end
end
