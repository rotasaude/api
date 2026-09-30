require "rails_helper"

# Spec §3.4 (calibração) e desvios 1 e 2 do plano: um atendimento por triagem
# (triage_id é único); o atendimento do retorno, que nasce do horário, não conta.
RSpec.describe Analytics::Consolidate::Calibration do
  let(:day) { Time.zone.today - 3 }
  let(:unit) { create_unit("UBS Centro") }
  let!(:protocol) { create_default_protocol! }

  def run!(from = day, to = day) = described_class.call(from: from, to: to, at: Time.current)

  def rows
    AnalyticsDailyFact.where(metric: "calibration.outcome").pluck(:day, :protocol_name, :protocol_version, :tier, :dim, :value)
  end

  it "sem atendimento é none; com atendimento encerrado, o desfecho; em atendimento ainda é none; revogada não entra" do
    a_triage!(day: day, tier: "alta")
    an_attendance!(triage: a_triage!(day: day, tier: "alta"), unit: unit, outcome: "discharged")
    an_attendance!(triage: a_triage!(day: day, tier: "baixa"), unit: unit, stage: :in_care)
    an_attendance!(triage: a_triage!(day: day, tier: "alta", revoked: true), unit: unit, outcome: "left")
    a_triage!(day: day, status: "aborted_by_timeout")

    run!

    expect(rows).to contain_exactly(
      [ day, protocol.name, 1, "alta", "none", 1 ],
      [ day, protocol.name, 1, "alta", "discharged", 1 ],
      [ day, protocol.name, 1, "baixa", "none", 1 ]
    )
  end

  it "vale o atendimento da própria triagem, não o do retorno que veio do horário" do
    triage = a_triage!(day: day, tier: "alta")
    first = an_attendance!(triage: triage, unit: unit, outcome: "return")
    request = AnalyticsHistory.request!(origin: first, kind: "return", by: analytics_staff)
    appointment = AnalyticsHistory.appointment!(request: request, status: "checked_in",
                                                scheduled_at: local_at(day + 1, 9), by: analytics_staff)
    AnalyticsHistory.attendance!(citizen: request.citizen, appointment: appointment, unit: unit, by: analytics_staff,
                                 checked_in_at: appointment.ended_at, outcome: "referred", referral_unit: unit)

    run!

    expect(rows).to contain_exactly([ day, protocol.name, 1, "alta", "return", 1 ])
  end

  it "versões diferentes do mesmo protocolo ficam em linhas separadas" do
    v2 = ProtocolDefinition.create!(name: protocol.name, version: 2, status: "published", definition: protocol.definition.merge("version" => 2))
    a_triage!(day: day, tier: "alta")
    a_triage!(day: day, tier: "alta", protocol: v2)

    run!

    expect(rows).to contain_exactly([ day, protocol.name, 1, "alta", "none", 1 ], [ day, protocol.name, 2, "alta", "none", 1 ])
  end
end
