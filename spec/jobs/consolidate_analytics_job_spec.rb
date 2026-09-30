require "rails_helper"

RSpec.describe ConsolidateAnalyticsJob do
  let!(:city_record) { register_test_city! }

  before { create_default_protocol! }

  it "consolida a janela agendada da cidade e publica" do
    a_triage!(day: Time.zone.today - 2)

    described_class.perform_now

    expect(AnalyticsRun.sole).to have_attributes(kind: "scheduled", status: "succeeded",
                                                 window_from: Time.zone.today - 30, window_to: Time.zone.today - 1)
    expect(CityAnalyticsIndicator.where(city_id: city_record.id)).to exist
  end

  it "run que falha vira falha do job (fica visível no Solid Queue)" do
    allow(Analytics::Consolidate).to receive(:call).and_raise(RuntimeError, "boom")

    expect { described_class.perform_now }
      .to raise_error(EachCityJob::AggregatedFailure, /Analytics::Run::Failed: RuntimeError: boom/)
    expect(AnalyticsRun.sole.status).to eq("failed")
  end

  it "está no recurring.yml, às 2h30 de São Paulo, na fila housekeeping" do
    task = YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true).dig("production", "consolidate_analytics")
    expect(task).to eq("class" => "ConsolidateAnalyticsJob", "queue" => "housekeeping",
                       "schedule" => "every day at 2:30am America/Sao_Paulo")
  end
end
