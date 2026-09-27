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

  # F-01.3: a janela do agendamento de produção é a mesma constante que o job
  # usa por padrão — uma fonte só para os 90 dias da ADR-0014.
  describe "schedule" do
    let(:task) do
      ActiveSupport::ConfigurationFile.parse(Rails.root.join("config/recurring.yml"))
        .fetch("production").fetch("purge_inbound_raw")
    end

    it "keeps RAW_RETENTION_DAYS at 90 (ADR-0014) and uses it as the default window" do
      expect(described_class::RAW_RETENTION_DAYS).to eq(90)

      old = make_inbound(created_at: (described_class::RAW_RETENTION_DAYS + 1).days.ago)
      call_body
      expect(old.reload.raw).to be_nil
    end

    it "is scheduled in production against PurgeInboundRawJob at RAW_RETENTION_DAYS" do
      expect(task["class"]).to eq("PurgeInboundRawJob")
      expect(task["args"]).to eq("older_than_days" => described_class::RAW_RETENTION_DAYS)
    end
  end

  it "keeps raw of messages inside the window" do
    recent = make_inbound(created_at: 89.days.ago)

    call_body(older_than_days: 90)

    expect(recent.reload.raw).to eq(%({"text":"dado pessoal"}))
  end
end
