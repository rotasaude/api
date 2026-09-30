# spec/lib/analytics_history_spec.rb
require "rails_helper"

# O histórico do Analytics passa pelos CHECKs e triggers de cada tabela (nada
# é gravado "já pronto" onde o banco exige transição): se estas specs passam,
# as linhas são as que o domínio produziria.
RSpec.describe AnalyticsHistory do
  let(:unit) { create_unit("UBS Histórico") }
  let(:day) { Time.zone.today - 5 }
  let!(:protocol) { create_default_protocol! }

  it "concluída e revogada depois: segue completed, com o consentimento revogado e a conversa revoked" do
    triage = a_triage!(day: day, revoked: true, answers: { "tosse" => "true" })
    expect(triage.reload).to have_attributes(status: "completed", completed_at: local_at(day) + 6.minutes,
                                             answers: { "tosse" => "true" })
    expect(triage.conversation.reload.state).to eq("revoked")
    expect(triage.conversation.consents.sole.revoked_at).to be_present
  end

  it "abortada por revogação nasce anonimizada, sem respostas e sem bairro" do
    centro = Neighborhood.create!(name: "Centro", source: "manual")
    triage = a_triage!(day: day, neighborhood: centro, status: "aborted_by_revocation", answers: { "tosse" => "true" })
    expect(triage.reload).to have_attributes(answers: {}, neighborhood_id: nil, tier: nil)
    expect(triage.conversation.consents.sole.revoked_at).to be_present
  end

  it "em curso: conversa ativa, sem conclusão" do
    triage = a_triage!(day: day, status: "in_progress")
    expect(triage.reload).to have_attributes(status: "in_progress", completed_at: nil, tier: nil)
    expect(triage.conversation.state).to eq("consented")
  end

  it "atendimento percorre as transições reais; quem sai não é chamado" do
    closed = an_attendance!(triage: a_triage!(day: day), unit: unit, wait_minutes: 42, outcome: "referred")
    expect(closed.reload).to have_attributes(status: "closed", outcome: "referred", referral_unit_id: unit.id)
    expect(closed.called_at - closed.checked_in_at).to eq(42 * 60)
    expect(closed.closed_at - closed.called_at).to eq(15 * 60)

    left = an_attendance!(triage: a_triage!(day: day), unit: unit, wait_minutes: 50, outcome: "left")
    expect(left.reload).to have_attributes(status: "closed", called_at: nil)
    expect(left.closed_at - left.checked_in_at).to eq(50 * 60)

    expect(an_attendance!(triage: a_triage!(day: day), unit: unit, stage: :in_care).reload.status).to eq("in_care")
    expect(an_attendance!(triage: a_triage!(day: day), unit: unit, stage: :waiting).reload.status).to eq("waiting")
  end

  it "pedido e horários encerrados, coerentes com os CHECKs" do
    origin = an_attendance!(triage: a_triage!(day: day - 10), unit: unit, outcome: "return")
    request = AnalyticsHistory.request!(origin: origin, kind: "return", by: analytics_staff, status: "closed",
                                        closed_reason: "fulfilled", closed_at: local_at(day, 9, 10))
    checked_in = AnalyticsHistory.appointment!(request: request, status: "checked_in", scheduled_at: local_at(day, 9),
                                               by: analytics_staff)
    expect(checked_in).to have_attributes(status: "checked_in", ended_at: local_at(day, 9, 10), health_unit_id: unit.id)
    %w[no_show expired cancelled_by_citizen].each do |status|
      appointment = AnalyticsHistory.appointment!(request: request, status: status, scheduled_at: local_at(day, 14),
                                                  by: analytics_staff)
      expect(appointment.ended_at).to eq(AnalyticsHistory.ended_at(status, local_at(day, 14))), status
    end
    expect(AnalyticsHistory.ended_at("no_show", local_at(day, 14)).to_date).to eq(day)
  end
end
