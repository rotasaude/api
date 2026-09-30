require "rails_helper"

# Spec §3.4 (qualidade operacional) e desvio 12 do plano (faixas de espera).
RSpec.describe Analytics::Consolidate::Quality do
  let(:day) { Time.zone.today - 3 }
  let(:unit) { create_unit("UBS Centro") }
  let(:other_unit) { create_unit("UPA Norte", kind: "upa") }
  let!(:protocol) { create_default_protocol! }

  def run!(from = day, to = day) = described_class.call(from: from, to: to, at: Time.current)
  def rows(metric) = AnalyticsDailyFact.where(metric: metric).pluck(:day, :health_unit_id, :dim, :value)

  it "attendance.closed: dia do encerramento, por unidade e desfecho; em atendimento não entra" do
    2.times { an_attendance!(triage: a_triage!(day: day), unit: unit) }
    an_attendance!(triage: a_triage!(day: day), unit: unit, outcome: "left")
    an_attendance!(triage: a_triage!(day: day), unit: other_unit, outcome: "referred", referral_unit: unit)
    an_attendance!(triage: a_triage!(day: day), unit: unit, stage: :in_care)

    run!

    expect(rows("attendance.closed")).to contain_exactly(
      [ day, unit.id, "discharged", 2 ], [ day, unit.id, "left", 1 ], [ day, other_unit.id, "referred", 1 ]
    )
  end

  it "attendance.wait: faixa pela espera até a chamada, no dia da chamada; quem saiu sem chamada não entra" do
    [ 14, 15, 29, 30, 59, 60, 119, 120 ].each do |minutes|
      an_attendance!(triage: a_triage!(day: day, hour: 8), unit: unit, wait_minutes: minutes)
    end
    night = a_triage!(day: day - 1, hour: 23)
    an_attendance!(triage: night, unit: unit, checked_in_at: local_at(day - 1, 23, 50), wait_minutes: 20) # chamada 00h10
    an_attendance!(triage: a_triage!(day: day), unit: unit, outcome: "left", wait_minutes: 5)

    run!

    expect(rows("attendance.wait")).to contain_exactly(
      [ day, unit.id, "0-15", 1 ], [ day, unit.id, "15-30", 3 ], [ day, unit.id, "30-60", 2 ],
      [ day, unit.id, "60-120", 2 ], [ day, unit.id, "120+", 1 ]
    )
  end

  it "appointment.ended: por unidade e estado final, no dia do fim; horário vivo não entra" do
    origin = an_attendance!(triage: a_triage!(day: day - 20), unit: unit, outcome: "return")
    request = AnalyticsHistory.request!(origin: origin, kind: "return", by: analytics_staff)
    AnalyticsHistory.appointment!(request: request, status: "checked_in", scheduled_at: local_at(day, 9), by: analytics_staff)
    AnalyticsHistory.appointment!(request: request, status: "no_show", scheduled_at: local_at(day, 10), by: analytics_staff)
    AnalyticsHistory.appointment!(request: request, status: "expired", scheduled_at: local_at(day + 1, 9), by: analytics_staff)
    AnalyticsHistory.appointment!(request: request, status: "cancelled_by_citizen", scheduled_at: local_at(day + 2, 9),
                                  by: analytics_staff)
    Appointment.create!(request: request, citizen: request.citizen, health_unit: unit, scheduled_by_user: analytics_staff,
                        scheduled_at: local_at(day, 11), status: "scheduled", confirmation_deadline_at: local_at(day, 8))

    run!

    expect(rows("appointment.ended")).to contain_exactly(
      [ day, unit.id, "checked_in", 1 ], [ day, unit.id, "no_show", 1 ],
      [ day, unit.id, "expired", 1 ], [ day, unit.id, "cancelled_by_citizen", 1 ]
    )
  end
end
