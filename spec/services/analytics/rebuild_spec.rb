# spec/services/analytics/rebuild_spec.rb
require "rails_helper"

# Spec §4.3: reconsolida em blocos de 30 dias, limitado ao cru que existe.
RSpec.describe Analytics::Rebuild do
  let!(:city_record) { register_test_city! }
  let(:today) { Time.zone.today }

  before { create_default_protocol! }

  def windows(report) = report.runs.map { |r| [ r.window_from, r.window_to, r.kind, r.status ] }

  it "sem cru: nada a fazer" do
    report = described_class.call
    expect(report.runs).to be_empty
    expect(report.busy).to be(false)
  end

  it "do cru mais antigo até ontem, em blocos de 30 dias" do
    a_triage!(day: today - 70, hour: 23, minute: 30)

    report = described_class.call

    expect(described_class.earliest_raw_day).to eq(today - 70)
    expect(windows(report)).to eq([
      [ today - 70, today - 41, "rebuild", "succeeded" ],
      [ today - 40, today - 11, "rebuild", "succeeded" ],
      [ today - 10, today - 1, "rebuild", "succeeded" ]
    ])
    expect(AnalyticsDailyFact.where(metric: "triage.started", day: today - 70).sum(:value)).to eq(1)
  end

  it "to depois de ontem é truncado; from explícito vale" do
    report = described_class.call(from: today - 5, to: today + 3)
    expect(windows(report)).to eq([ [ today - 5, today - 1, "rebuild", "succeeded" ] ])
  end

  it "outra consolidação em curso: para e informa" do
    a_triage!(day: today - 5)
    allow(Analytics::Run).to receive(:try_lock).and_return(false)

    report = described_class.call

    expect(report.busy).to be(true)
    expect(report.runs).to be_empty
  end

  it "bloco que falha interrompe os seguintes" do
    a_triage!(day: today - 70)
    allow(Analytics::Consolidate).to receive(:call).and_raise(RuntimeError, "boom")

    report = described_class.call

    expect(report.runs.size).to eq(1)
    expect(report.failed.error).to eq("RuntimeError: boom")
  end
end
