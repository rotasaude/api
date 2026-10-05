# spec/services/triages/counters_spec.rb
require "rails_helper"

# Spec 2026-10-05 §7 e contratos §4.1 (desvio 10 do plano): últimos 30 dias
# locais, agregados, 1 a 4 viram nil (ADR 0025); 0 continua 0.
RSpec.describe Triages::Counters do
  before { Current.city = TEST_CITY_A }
  after { Current.reset; Rails.cache.clear }

  let!(:mental) { active_protocol!("saude-mental") }
  let!(:deep) { active_protocol!("saude-mental-aprofundada") }

  def pair(index) = profiled_citizen!(age: 30, phone: format("+55419%08d", 40_000_000 + index))

  it "conta e suprime 1 a 4, na janela de 30 dias" do
    today = Time.zone.today
    TriageOfferDailyCount.create!(day: today, protocol_name: "saude-mental", offered: 7)
    TriageOfferDailyCount.create!(day: today - 29, protocol_name: "saude-mental", offered: 3)
    TriageOfferDailyCount.create!(day: today - 30, protocol_name: "saude-mental", offered: 100) # fora
    5.times { |i| completed_triage!(pair(i), "saude-mental") }
    completed_triage!(pair(10), "saude-mental", at: 31.days.ago) # fora
    6.times do |i|
      citizen = pair(20 + i)
      source = completed_triage!(citizen, "saude-mental")
      taken = completed_triage!(citizen, "saude-mental-aprofundada")
      TriageSuggestion.create!(citizen: citizen, source_triage: source, protocol_name: "saude-mental-aprofundada",
                               status: "taken", taken_triage_id: taken.id, resolved_at: Time.current)
    end

    counters = described_class.for(%w[saude-mental saude-mental-aprofundada fantasma])
    expect(counters["saude-mental"]).to eq(offered: 10, started: 11, completed: 11, from_suggestion: 0)
    expect(counters["saude-mental-aprofundada"]).to eq(offered: 0, started: 6, completed: 6, from_suggestion: 6)
    expect(counters["fantasma"]).to eq(offered: 0, started: 0, completed: 0, from_suggestion: 0)

    TriageOfferDailyCount.where(protocol_name: "saude-mental").delete_all
    TriageOfferDailyCount.create!(day: today, protocol_name: "saude-mental", offered: 4)
    expect(described_class.for(%w[saude-mental])["saude-mental"][:offered]).to be_nil
  end

  it "concluída revogada não conta como concluída" do
    5.times do |i|
      triage = completed_triage!(pair(50 + i), "saude-mental")
      triage.update_columns(status: "aborted_by_revocation")
    end
    expect(described_class.for(%w[saude-mental])["saude-mental"]).to include(started: 5, completed: 0)
  end
end
