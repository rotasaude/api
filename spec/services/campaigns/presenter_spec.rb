require "rails_helper"

RSpec.describe Campaigns::Presenter do
  it "rascunho: campos nulos e stats nulo" do
    campaign = draft_campaign!
    expect(described_class.full(campaign)).to include(
      id: campaign.id, status: "draft", send_at: nil, dispatched_at: nil, recipients_count: nil, failure_reason: nil,
      sms_enabled: nil, phones_count: nil, stats: nil, created_at: campaign.created_at.iso8601
    )
    expect(described_class.summary(campaign).keys).to eq(%i[id title status send_at dispatched_at recipients_count])
  end

  it "stats é nulo em todo status que não seja sent, inclusive failed" do
    %w[draft scheduled sending failed cancelled].each do |status|
      campaign = draft_campaign!
      campaign.status = status
      expect(described_class.full(campaign)[:stats]).to be_nil, status
    end
  end

  it "enviada: lidos e as 7 chaves de SMS, sem lista de destinatários" do
    campaign = sent_campaign!
    recipient!(campaign, person!, sms_status: "sent").update!(notice_read_at: Time.current)
    recipient!(campaign, person!, sms_status: "unavailable")
    full = described_class.full(campaign)
    expect(full[:stats]).to eq(read_count: 1, sms: { "not_opted_in" => 0, "duplicate_phone" => 0, "pending" => 0,
                                                     "deferred" => 0, "sent" => 1, "failed" => 0, "unavailable" => 1 })
    expect(full.to_json).not_to include("citizen")
    expect(full[:dispatched_at]).to eq(campaign.dispatched_at.iso8601)
  end
end
