require "rails_helper"

RSpec.describe Campaigns::DueJob do
  include ActiveSupport::Testing::TimeHelpers

  let!(:city_record) { register_test_city! }

  def scheduled!(send_at) = draft_campaign!.tap { |c| c.update_columns(status: "scheduled", send_at: send_at) }

  it "solta só o que venceu (inclusive no segundo exato) e enfileira um DispatchJob por campanha" do
    freeze_time do
      late = scheduled!(1.minute.ago)
      exact = scheduled!(Time.current)
      future = scheduled!(1.minute.from_now)
      draft = draft_campaign!

      expect { described_class.perform_now }.to have_enqueued_job(Campaigns::DispatchJob).exactly(2).times
      expect([ late, exact, future, draft ].map { |c| c.reload.status }).to eq(%w[sending sending scheduled draft])
    end
  end

  it "duas execuções seguidas não enfileiram em dobro" do
    scheduled!(1.minute.ago)
    expect { described_class.perform_now; described_class.perform_now }
      .to have_enqueued_job(Campaigns::DispatchJob).exactly(1).times
  end

  it "cancelada ou desagendada antes do horário não sai" do
    cancelled = scheduled!(1.minute.from_now)
    Campaigns::Cancel.call(campaign: cancelled, by: cancelled.created_by_user)
    unscheduled = scheduled!(1.minute.from_now)
    Campaigns::Unschedule.call(campaign: unscheduled, by: unscheduled.created_by_user)
    travel_to(2.minutes.from_now) do
      expect { described_class.perform_now }.not_to have_enqueued_job(Campaigns::DispatchJob)
    end
    expect([ cancelled.reload.status, unscheduled.reload.status ]).to eq(%w[cancelled draft])
  end

  it "está no recurring.yml, a cada minuto, na fila default" do
    task = YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true).dig("production", "campaigns_due")
    expect(task).to eq("class" => "Campaigns::DueJob", "queue" => "default", "schedule" => "every minute")
  end
end
