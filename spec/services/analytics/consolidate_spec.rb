# spec/services/analytics/consolidate_spec.rb
require "rails_helper"

# Spec §4.1: a consolidação apaga só os fatos da janela e os regrava do cru.
RSpec.describe Analytics::Consolidate do
  let(:day) { Time.zone.today - 3 }
  let!(:protocol) { create_default_protocol! }

  it "apaga os fatos da janela (e só eles) antes de regravar" do
    outside = fact!(metric: "triage.started", day: day - 1, value: 7)
    fact!(metric: "triage.started", day: day, value: 99, protocol_name: "fantasma")
    a_triage!(day: day)

    described_class.call(from: day, to: day)

    expect(AnalyticsDailyFact.where(day: day).pluck(:metric, :protocol_name, :value))
      .to include([ "triage.started", protocol.name, 1 ])
    expect(AnalyticsDailyFact.where(protocol_name: "fantasma")).to be_empty
    expect(outside.reload.value).to eq(7)
  end
end
