require "rails_helper"

# api#31: retenção dos dados do canal do cidadão (OTP, sessões, mensagens).
RSpec.describe PurgeCitizenChannelJob, type: :job do
  include ActiveSupport::Testing::TimeHelpers

  before { Current.city = TEST_CITY_A }

  def call_body
    described_class.instance_method(:perform).super_method.bind_call(described_class.new)
  end

  def otp(expires_at:)
    OtpChallenge.create!(phone: "5541999990001", code_digest: "x", expires_at: expires_at, created_at: expires_at - 10.minutes)
  end

  def session(expires_at: 1.day.from_now, revoked_at: nil)
    CitizenSession.create!(phone: "5541999990001", token_digest: SecureRandom.hex(16),
                           expires_at: expires_at, revoked_at: revoked_at)
  end

  def outbound(created_at:)
    OutboundMessage.create!(to: "5541999990001", template: { name: "t" }, idempotency_key: SecureRandom.hex(8),
                            status: 200, created_at: created_at)
  end

  def inbound(created_at:, raw: nil)
    InboundMessage.create!(message_id: "wamid.#{SecureRandom.hex(8)}", from: "5541999990001",
                           kind: "text", raw: raw, created_at: created_at)
  end

  it "pins the decided retention values" do
    expect(described_class::OTP_AFTER_EXPIRY).to eq(7.days)
    expect(described_class::SESSION_AFTER_END).to eq(30.days)
    expect(described_class::OUTBOUND_RETENTION).to eq(90.days)
    expect(described_class::INBOUND_RETENTION).to eq(12.months)
  end

  it "deletes OTP challenges expired more than 7 days ago and keeps newer ones" do
    freeze_time do
      old = otp(expires_at: 7.days.ago - 1.second)
      inside = otp(expires_at: 7.days.ago + 1.minute)
      live = otp(expires_at: 5.minutes.from_now)

      call_body

      expect(OtpChallenge.exists?(old.id)).to be(false)
      expect(OtpChallenge.exists?(inside.id)).to be(true)
      expect(OtpChallenge.exists?(live.id)).to be(true)
    end
  end

  it "deletes sessions expired or revoked more than 30 days ago and keeps the rest" do
    freeze_time do
      expired_old = session(expires_at: 30.days.ago - 1.second)
      revoked_old = session(revoked_at: 30.days.ago - 1.second)
      expired_inside = session(expires_at: 30.days.ago + 1.minute)
      revoked_inside = session(revoked_at: 30.days.ago + 1.minute)
      active = session

      call_body

      expect(CitizenSession.exists?(expired_old.id)).to be(false)
      expect(CitizenSession.exists?(revoked_old.id)).to be(false)
      expect(CitizenSession.exists?(expired_inside.id)).to be(true)
      expect(CitizenSession.exists?(revoked_inside.id)).to be(true)
      expect(CitizenSession.exists?(active.id)).to be(true)
    end
  end

  it "deletes outbound messages older than 90 days and keeps newer ones" do
    freeze_time do
      old = outbound(created_at: 90.days.ago - 1.second)
      inside = outbound(created_at: 90.days.ago + 1.minute)

      call_body

      expect(OutboundMessage.exists?(old.id)).to be(false)
      expect(OutboundMessage.exists?(inside.id)).to be(true)
    end
  end

  it "deletes inbound rows older than 12 months, and keeps newer ones even with raw already cleared" do
    freeze_time do
      old = inbound(created_at: 12.months.ago - 1.second)
      inside_cleared = inbound(created_at: 12.months.ago + 1.minute, raw: nil)
      inside_raw = inbound(created_at: 1.day.ago, raw: %({"a":1}))

      call_body

      expect(InboundMessage.exists?(old.id)).to be(false)
      expect(InboundMessage.exists?(inside_cleared.id)).to be(true)
      expect(InboundMessage.exists?(inside_raw.id)).to be(true)
    end
  end

  it "logs counts only, never ids or phones" do
    otp(expires_at: 8.days.ago)
    allow(Rails.logger).to receive(:info)

    call_body

    expect(Rails.logger).to have_received(:info).with(/otp_challenges=1/)
    expect(Rails.logger).not_to have_received(:info).with(/5541999990001/)
  end

  it "runs once per active city (EachCityJob)" do
    city_a = create(:city, database_url: city_database_url("rota_saude_test_city_a"))
    city_b = create(:city, database_url: city_database_url("rota_saude_test_city_b"))
    old_a = CityConnection.with(city_a) { otp(expires_at: 8.days.ago).id }
    old_b = CityConnection.with(city_b) { otp(expires_at: 8.days.ago).id }

    described_class.new.perform

    expect(CityConnection.with(city_a) { OtpChallenge.exists?(old_a) }).to be(false)
    expect(CityConnection.with(city_b) { OtpChallenge.exists?(old_b) }).to be(false)
  end

  it "is scheduled daily on housekeeping in the city recurring file" do
    task = ActiveSupport::ConfigurationFile.parse(Rails.root.join("config/recurring.yml"))
      .fetch("production").fetch("purge_citizen_channel")

    expect(task).to include("class" => "PurgeCitizenChannelJob", "queue" => "housekeeping")
    expect(task["schedule"]).to match(/every day/)
  end
end
