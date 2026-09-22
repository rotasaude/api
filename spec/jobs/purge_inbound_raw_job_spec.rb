require "rails_helper"

RSpec.describe PurgeInboundRawJob, type: :job do
  before { Current.city = TEST_CITY_A }

  def make_inbound(created_at:)
    InboundMessage.create!(
      message_id: "wamid.#{SecureRandom.hex(8)}", from: "5541999990000",
      kind: "text", raw: %({"text":"dado pessoal"}), created_at: created_at
    )
  end

  # PurgeInboundRawJob prepends EachCityJob; chamamos o corpo direto, como
  # purge_domain_events_job_spec, na conexão da cidade que o harness abriu.
  def call_body(**kwargs)
    described_class.instance_method(:perform).super_method.bind_call(described_class.new, **kwargs)
  end

  # ADR-0014: o raw "vira NULL após a janela"; metadados ficam para auditoria.
  it "clears raw of messages older than the window and keeps their metadata" do
    old = make_inbound(created_at: 91.days.ago)

    call_body(older_than_days: 90)

    old.reload
    expect(old.raw).to be_nil
    expect(old.message_id).to be_present
    expect(old.from).to eq("5541999990000")
  end

  it "keeps raw of messages inside the window" do
    recent = make_inbound(created_at: 89.days.ago)

    call_body(older_than_days: 90)

    expect(recent.reload.raw).to eq(%({"text":"dado pessoal"}))
  end
end
