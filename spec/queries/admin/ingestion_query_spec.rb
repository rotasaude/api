require "rails_helper"

# F-01.10: painel de saúde da ingestão — volume inbound, ack aproximado e
# backlog de purga do raw. O backlog segue a retenção real do raw
# (PurgeInboundRawJob::RAW_RETENTION_DAYS), não um TTL próprio.
RSpec.describe Admin::IngestionQuery do
  def period = Admin::Api::Period.parse(key: "7d", from: nil, to: nil, tz: ActiveSupport::TimeZone["America/Sao_Paulo"])

  def make_inbound(created_at:, raw: %({"text":"oi"}))
    InboundMessage.create!(
      message_id: "wamid.#{SecureRandom.hex(8)}", from: "5541999990000",
      kind: "text", raw: raw, created_at: created_at
    )
  end

  it "counts inbound volume of the period" do
    make_inbound(created_at: 1.day.ago)
    make_inbound(created_at: 2.days.ago)
    make_inbound(created_at: 30.days.ago)

    out = described_class.call(period: period)

    expect(out[:inboundTotal]).to eq(2)
  end

  it "uses the raw retention window as the purge TTL" do
    out = described_class.call(period: period)

    expect(out[:purge][:ttlH]).to eq(PurgeInboundRawJob::RAW_RETENTION_DAYS * 24)
  end

  it "counts only rows whose raw is still stored and older than the retention" do
    make_inbound(created_at: 100.days.ago)             # pendente
    make_inbound(created_at: 100.days.ago, raw: nil)   # já purgado
    make_inbound(created_at: 10.days.ago)              # dentro da retenção

    purge = described_class.call(period: period)[:purge]

    expect(purge[:pending]).to eq(1)
    expect(purge[:oldestH]).to be_within(1).of(100 * 24)
    expect(purge[:overTtl]).to be(true)
  end

  it "ignores purged rows when measuring the oldest raw" do
    make_inbound(created_at: 200.days.ago, raw: nil)
    make_inbound(created_at: 10.days.ago)

    purge = described_class.call(period: period)[:purge]

    expect(purge[:pending]).to eq(0)
    expect(purge[:oldestH]).to be_within(1).of(10 * 24)
    expect(purge[:overTtl]).to be(false)
  end

  it "does not expose a dedup metric" do
    expect(described_class.call(period: period)).not_to have_key(:dedup)
  end
end
