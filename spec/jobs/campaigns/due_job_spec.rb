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

  describe "campanhas presas em sending" do
    def sending!(entered_at)
      draft_campaign!.tap { |c| c.update_columns(status: "sending", updated_at: entered_at) }
    end


    it "reenfileira o DispatchJob de quem está em sending há mais de 10 minutos, só com city_slug e campaign_id" do
      stale = sending!(11.minutes.ago)
      expect { described_class.perform_now }.to have_enqueued_job(Campaigns::DispatchJob)
        .with(city_slug: Current.city.slug, campaign_id: stale.id).exactly(:once)
      expect(stale.reload.status).to eq("sending")
    end

    it "não mexe em quem entrou em sending há 1 minuto" do
      sending!(1.minute.ago)
      expect { described_class.perform_now }.not_to have_enqueued_job(Campaigns::DispatchJob)
    end

    it "desiste de quem está em sending há mais de 24 horas" do
      sending!(25.hours.ago)
      expect { described_class.perform_now }.not_to have_enqueued_job(Campaigns::DispatchJob)
    end
  end

  describe "SMS encalhado de campanha enviada" do
    let(:campaign) { sent_campaign!(sms_enabled: true) }
    let(:ten_am) { Time.zone.now.change(hour: 10) }

    def stuck!(status, created_at:)
      travel_to(created_at) { recipient!(campaign, person!.tap { |p| opt_in!(p) }, sms_status: status) }
    end

    def batch_job = have_enqueued_job(Campaigns::SmsBatchJob)

    it "reenfileira o lote de quem tem pending há mais de 10 minutos, uma vez por campanha, só com slug e id" do
      stuck!("pending", created_at: ten_am - 11.minutes)
      stuck!("pending", created_at: ten_am - 30.minutes)
      travel_to(ten_am) do
        expect { described_class.perform_now }
          .to batch_job.with(city_slug: Current.city.slug, campaign_id: campaign.id).exactly(:once)
      end
    end

    it "pending parado fora da janela também volta (o lote é quem adia para as 8h)" do
      stuck!("pending", created_at: ten_am.change(hour: 22) - 11.minutes)
      travel_to(ten_am.change(hour: 22)) { expect { described_class.perform_now }.to batch_job.exactly(:once) }
    end

    it "não mexe em pending com menos de 10 minutos" do
      stuck!("pending", created_at: ten_am - 9.minutes)
      travel_to(ten_am) { expect { described_class.perform_now }.not_to batch_job }
    end

    it "deferred dentro da janela 8h–20h volta, inclusive às 8h em ponto e às 19h59" do
      stuck!("deferred", created_at: ten_am - 1.day)
      [ ten_am.change(hour: 8), ten_am, ten_am.change(hour: 19, min: 59) ].each do |at|
        travel_to(at) { expect { described_class.perform_now }.to batch_job.exactly(:once) }
      end
    end

    it "deferred fora da janela (7h59, 20h, 22h, 6h) não volta" do
      stuck!("deferred", created_at: ten_am - 1.day)
      [ ten_am.change(hour: 7, min: 59), ten_am.change(hour: 20), ten_am.change(hour: 22), ten_am.change(hour: 6) ]
        .each { |at| travel_to(at) { expect { described_class.perform_now }.not_to batch_job } }
    end

    it "ignora linhas já resolvidas e campanhas sem SMS" do
      %w[sent failed unavailable not_opted_in duplicate_phone].each { |s| stuck!(s, created_at: ten_am - 1.hour) }
      without_sms = sent_campaign!(sms_enabled: false)
      travel_to(ten_am - 1.hour) { recipient!(without_sms, person!, sms_status: "not_opted_in") }
      travel_to(ten_am) { expect { described_class.perform_now }.not_to batch_job }
    end

    it "idempotente: DueJob repetido e lotes repetidos entregam cada SMS uma vez só" do
      rows = [ stuck!("pending", created_at: ten_am - 20.minutes), stuck!("deferred", created_at: ten_am - 1.day) ]
      travel_to(ten_am) do
        expect { 2.times { described_class.perform_now } }.to batch_job.exactly(2).times
        2.times { Campaigns::SmsBatchJob.perform_now(city_slug: Current.city.slug, campaign_id: campaign.id) }
        expect { described_class.perform_now }.not_to batch_job
      end
      expect(rows.map { |r| r.reload.sms_status }).to eq(%w[sent sent])
      expect(SmsGateway::Test.deliveries.map { |d| d[:phone] }).to match_array(rows.map { |r| r.citizen.phone })
    end
  end

  it "está no recurring.yml, a cada minuto, na fila default" do
    task = YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true).dig("production", "campaigns_due")
    expect(task).to eq("class" => "Campaigns::DueJob", "queue" => "default", "schedule" => "every minute")
  end
end
