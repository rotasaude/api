require "rails_helper"

# Contratos §1 (as_of, stale) e §3 (analyticsStatus).
RSpec.describe Analytics::Status do
  it "nunca rodou: tudo nulo e stale" do
    expect(described_class.call.to_h).to eq(last_run_status: nil, last_succeeded_at: nil, last_published_at: nil,
                                            last_error: nil, stale: true)
  end

  it "último run, último succeeded e último publicado; stale depois de 36 h" do
    succeeded = consolidated_run!(finished_at: 40.hours.ago)
    AnalyticsRun.create!(kind: "scheduled", status: "failed", window_from: Time.zone.today - 30,
                         window_to: Time.zone.today - 1, started_at: 1.hour.ago, finished_at: 1.hour.ago,
                         error: "RuntimeError: boom")

    status = described_class.call

    expect(status).to have_attributes(last_run_status: "failed", last_error: "RuntimeError: boom", stale: true)
    expect(status.last_succeeded_at).to be_within(1.second).of(succeeded.finished_at)
    expect(status.last_published_at).to be_within(1.second).of(succeeded.published_at)
    expect(described_class.call(now: succeeded.finished_at + 35.hours).stale).to be(false)
  end
end
