require "rails_helper"

# api#43 (ADR 0030, Invariantes): nenhum payload de ficha rejected/failed com
# última tentativa há mais de 90 dias.
RSpec.describe Ledi::PurgeStalePayloadsJob do
  include ActiveSupport::Testing::TimeHelpers

  let!(:city) { register_test_city! }

  def entry!(status, attempted_at:)
    attrs = { uuid: "1234567-#{SecureRandom.uuid}", ficha_type: "procedimento", competence: "202606",
              source_type: "synthetic", source_id: SecureRandom.uuid, ledi_version: "8.7.0", status: status,
              next_attempt_at: Time.current, attempts: 1, last_attempted_at: attempted_at, bytes: "x".b }
    attrs[:last_error_codes] = [ { "field" => "cnes", "code" => "invalid" } ] if status == "rejected"
    CityConnection.with(city) { LediOutboxEntry.create!(attrs) }
  end

  def payload_of(entry) = CityConnection.with(city) { entry.reload.payload }

  it "apaga o conteúdo de recusada/falha com 90+ dias; o resto fica; evento só com a contagem" do
    old_rejected = entry!("rejected", attempted_at: 91.days.ago)
    old_failed = entry!("failed", attempted_at: 120.days.ago)
    recent = entry!("rejected", attempted_at: 89.days.ago)
    pending = entry!("pending", attempted_at: 200.days.ago)

    described_class.perform_now

    expect([ old_rejected, old_failed ].map { |e| payload_of(e) }).to eq([ nil, nil ])
    expect([ recent, pending ].map { |e| payload_of(e) }).to all(be_present)
    events = CityConnection.with(city) { DomainEvent.where(name: "ledi.payload_purged").pluck(:payload) }
    expect(events).to eq([ { "count" => 2 } ])
  end

  it "sem nada vencido não publica evento; o recurring.yml usa os mesmos 90 dias" do
    entry!("rejected", attempted_at: 10.days.ago)
    described_class.perform_now
    expect(CityConnection.with(city) { DomainEvent.where(name: "ledi.payload_purged").count }).to eq(0)
    task = YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true).dig("default", "ledi_purge_stale_payloads")
    expect(task).to include("class" => "Ledi::PurgeStalePayloadsJob", "args" => { "older_than_days" => 90 })
  end
end
