require "rails_helper"

# Módulo 29, Task 13 (ADR 0047, Desvio 13; §15 V8, V23): o alerta de 24 h é
# contagem calculada na leitura, com a MESMA regra das pendências da sala
# (Vaccination::Pending): `late` = não aceita e `deadline_at` vencido,
# incluindo `sending`; doses sem nada a fazer na RNDS ficam de fora.
RSpec.describe Rnds::Alert do
  include ActiveSupport::Testing::TimeHelpers

  let!(:city) { vaccination_city! }
  let(:room) { vaccine_room! }

  # Dose com a entrada `application` no status pedido (prazo = applied_at + 24 h).
  def dose_with(status, applied_at: 2.days.ago, **attrs)
    dose = create_immunization!(room, applied_at: applied_at)
    entry = Rnds::Enqueue.call(dose, kind: "application")
    extra = { "accepted" => { accepted_at: Time.current }, "blocked" => { block_reason: "patient_without_cns_or_cpf" } }
    entry.update_columns({ status: status }.merge(extra.fetch(status, {})).merge(attrs))
    dose
  end

  def cancel_directly!(dose) = dose.update!(cancelled_at: Time.current, cancelled_by_user: room_member!(room), cancel_reason: "registro duplicado")

  it "late conta pending, sending, blocked, rejected e failed com prazo vencido; accepted e no prazo não" do
    %w[pending sending blocked rejected failed accepted].each { |status| dose_with(status) }
    dose_with("pending", applied_at: 1.hour.ago)
    expect(described_class.counts(now: Time.current)).to eq(pending: 3, blocked: 1, rejected: 1, failed: 1, late: 5)
  end

  it "com o envio desligado, pending não conta como atraso (nada sairá até ligar)" do
    %w[pending blocked].each { |status| dose_with(status) }
    expect(described_class.counts(now: Time.current, rnds_enabled: false)).to include(pending: 1, late: 1)
  end

  it "dose cancelada sem nada a fazer na RNDS (original rejected, ou nunca tentado) fica de fora" do
    rejected = dose_with("rejected")
    never = dose_with("pending")
    [ rejected, never ].each { |dose| cancel_directly!(dose) }
    expect(described_class.counts(now: Time.current)).to eq(pending: 0, blocked: 0, rejected: 0, failed: 0, late: 0)
  end

  it "cancelamento conta só depois do aceite do original; órfão (original recusado) nunca conta" do
    waiting = dose_with("sending", first_attempt_at: 2.days.ago)
    cancel_directly!(waiting)
    Rnds::Enqueue.call(waiting, kind: "cancellation", now: 2.days.ago)
    expect(described_class.counts(now: Time.current)).to include(pending: 1, late: 1) # a application em voo

    RndsOutboxEntry.find_by(immunization_id: waiting.id, kind: "application").update_columns(status: "rejected")
    expect(described_class.counts(now: Time.current)).to eq(pending: 0, blocked: 0, rejected: 0, failed: 0, late: 0)

    accepted = dose_with("accepted")
    cancel_directly!(accepted)
    Rnds::Enqueue.call(accepted, kind: "cancellation", now: 2.days.ago)
    expect(described_class.counts(now: Time.current)).to include(pending: 1, late: 1)
  end

  it "aceita um escopo e bate com as pendências da sala" do
    dose_with("rejected")
    other_room = vaccine_room!
    RndsOutboxEntry.find_by(immunization_id: create_immunization!(other_room, applied_at: 2.days.ago).tap { |d| Rnds::Enqueue.call(d, kind: "application") }.id)
                   .update_columns(status: "failed")
    scope = RndsOutboxEntry.joins(:immunization).where(immunizations: { vaccine_room_id: room.id })
    expect(described_class.counts(scope, now: Time.current)).to include(rejected: 1, failed: 0, late: 1)
    expect(Vaccination::Pending.counts(room, rnds_enabled: true)).to eq(blocked: 0, rejected: 1, failed: 0, late: 1)
  end
end
