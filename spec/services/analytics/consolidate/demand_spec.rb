# spec/services/analytics/consolidate/demand_spec.rb
require "rails_helper"

# Spec 2026-09-30 §3.4 (demanda) e desvio 1 do plano (revogação). Cada
# métrica: entra, não entra, borda do dia no fuso da cidade.
RSpec.describe Analytics::Consolidate::Demand do
  let(:day) { Time.zone.today - 3 }
  let(:centro) { Neighborhood.create!(name: "Centro", source: "manual") }
  let(:unit) { create_unit("UBS Centro") }
  let(:other_unit) { create_unit("UPA Norte", kind: "upa") }
  let!(:protocol) { create_default_protocol! }

  def run!(from = day, to = day) = described_class.call(from: from, to: to, at: Time.current)

  def rows(metric)
    AnalyticsDailyFact.where(metric: metric)
                      .pluck(:day, :health_unit_id, :neighborhood_id, :protocol_name, :protocol_version, :tier, :dim, :value)
  end

  it "triage.started: dia do início no fuso da cidade, por bairro, protocolo e versão" do
    2.times { a_triage!(day: day, hour: 9, neighborhood: centro) }
    a_triage!(day: day, hour: 23, minute: 30, neighborhood: centro) # 02h30 UTC do dia seguinte: conta em `day`
    a_triage!(day: day, hour: 11, status: "in_progress")             # sem bairro
    a_triage!(day: day + 1, hour: 0, minute: 10, neighborhood: centro)
    a_triage!(day: day - 1, hour: 23, minute: 50, neighborhood: centro)

    run!

    expect(rows("triage.started")).to contain_exactly(
      [ day, nil, centro.id, protocol.name, 1, nil, "", 3 ],
      [ day, nil, nil, protocol.name, 1, nil, "", 1 ]
    )
  end

  it "triage.completed: dia da conclusão, com tier; revogada depois de concluir não entra" do
    a_triage!(day: day, neighborhood: centro, tier: "alta")
    a_triage!(day: day, neighborhood: centro, tier: "baixa")
    a_triage!(day: day, neighborhood: centro, tier: "alta", revoked: true)
    a_triage!(day: day, hour: 23, minute: 57, neighborhood: centro) # conclui 00h03 do dia seguinte

    run!

    expect(rows("triage.completed")).to contain_exactly(
      [ day, nil, centro.id, protocol.name, 1, "alta", "", 1 ],
      [ day, nil, centro.id, protocol.name, 1, "baixa", "", 1 ]
    )
  end

  it "triage.aborted: tempo esgotado, cancelamento e revogação; a revogação perde o bairro" do
    a_triage!(day: day, neighborhood: centro, status: "aborted_by_timeout")
    a_triage!(day: day, neighborhood: centro, status: "aborted_by_cancellation")
    a_triage!(day: day, neighborhood: centro, status: "aborted_by_revocation")
    a_triage!(day: day, neighborhood: centro, revoked: true) # revogada depois de concluir

    run!

    expect(rows("triage.aborted")).to contain_exactly(
      [ day, nil, centro.id, protocol.name, 1, nil, "timeout", 1 ],
      [ day, nil, centro.id, protocol.name, 1, nil, "cancellation", 1 ],
      [ day, nil, nil, protocol.name, 1, nil, "revocation", 2 ]
    )
    expect(rows("triage.started")).to contain_exactly(
      [ day, nil, centro.id, protocol.name, 1, nil, "", 2 ],
      [ day, nil, nil, protocol.name, 1, nil, "", 2 ]
    )
  end

  it "attendance.checked_in: por unidade e método, no dia do check-in" do
    late = a_triage!(day: day - 1, hour: 22)
    an_attendance!(triage: late, unit: unit, checked_in_at: local_at(day, 0, 20))
    an_attendance!(triage: a_triage!(day: day), unit: unit, check_in_method: "cpf_exception")
    an_attendance!(triage: a_triage!(day: day), unit: other_unit, stage: :waiting)
    an_attendance!(triage: a_triage!(day: day - 1), unit: unit) # chega em day - 1: fora

    run!

    expect(rows("attendance.checked_in")).to contain_exactly(
      [ day, unit.id, nil, nil, nil, nil, "code", 1 ],
      [ day, unit.id, nil, nil, nil, nil, "cpf_exception", 1 ],
      [ day, other_unit.id, nil, nil, nil, nil, "code", 1 ]
    )
  end

  it "request.opened e request.closed: pela unidade-alvo, por tipo e por motivo" do
    back = an_attendance!(triage: a_triage!(day: day - 2), unit: unit, outcome: "return")
    sent = an_attendance!(triage: a_triage!(day: day - 2), unit: unit, outcome: "referred", referral_unit: other_unit)
    AnalyticsHistory.request!(origin: back, kind: "return", by: analytics_staff, created_at: local_at(day, 9))
    AnalyticsHistory.request!(origin: sent, kind: "referral", target: other_unit, by: analytics_staff,
                              created_at: local_at(day - 2, 16), status: "closed", closed_reason: "dismissed",
                              closed_at: local_at(day, 15))

    run!

    expect(rows("request.opened")).to contain_exactly([ day, unit.id, nil, nil, nil, nil, "return", 1 ])
    expect(rows("request.closed")).to contain_exactly([ day, other_unit.id, nil, nil, nil, nil, "dismissed", 1 ])
  end
end
