require "rails_helper"

# ADR 0036 (spec §5; contrato §1; Desvio 11): a tabela de transições, o
# prazo da próxima etapa, motivo obrigatório e eventos só com ids.
RSpec.describe Exams::Transition do
  include ActiveSupport::Testing::TimeHelpers

  before { exam_city! }

  let(:unit) { create_unit("UBS Transição") }
  let(:doctor) { doctor!(unit) }
  let(:patient) { exam_patient!(10).first }
  let(:provider) { exam_provider! }

  def open(sigtap: "0202010503", priority: "routine", **item)
    exam_catalog_item!(sigtap_code: sigtap, **item)
    Exams::Open.call(patient: patient, sigtap_code: sigtap, priority: priority, unit: unit, origin: "pec",
                     requester_user: doctor, created_by: doctor).payload.fetch(:order)
  end

  def step(order, kind, **opts)
    ApplicationRecord.transaction do
      order.lock!
      described_class.call(order: order, kind: kind, actor_user: doctor, **opts)
    end
  end

  it "abre aguardando agendamento (ou autorização), com prazo, evento requested e código curto" do
    travel_to Time.zone.local(2026, 10, 13, 10) do
      order = open
      expect(order).to have_attributes(status: "awaiting_schedule", stage: "schedule", stage_due_on: Date.new(2026, 10, 28))
      expect(order.short_code).to match(/\A[23456789ABCDEFGHJKMNPQRSTUVWXYZ]{10}\z/)
      expect(order.events.map(&:kind)).to eq(%w[requested])
      expect(DomainEvent.where(name: "exam_order.requested").last.payload)
        .to eq("exam_order_id" => order.id, "origin" => "pec", "priority" => "routine")
      urgent = open(sigtap: "0202020380", priority: "urgent", requires_authorization: true)
      expect(urgent).to have_attributes(status: "awaiting_authorization", stage: "authorize", stage_due_on: Date.new(2026, 10, 21))
    end
  end

  it "percorre o ciclo inteiro e cada evento guarda o prazo da etapa que fechou" do
    order = open(requires_authorization: true)
    expect(step(order, "authorized", changes: { exam_provider_id: provider.id })).to be_ok
    expect(order.reload).to have_attributes(status: "awaiting_schedule", exam_provider_id: provider.id, stage: "schedule")
    step(order, "scheduled", changes: { scheduled_at: 2.days.from_now, scheduled_place: "Rua A, 10" })
    step(order, "scheduled", changes: { scheduled_at: 3.days.from_now, scheduled_place: "Rua A, 10" })
    step(order, "collected")
    step(order, "resulted", event_payload: { source: "unit", critical: false })
    step(order, "acknowledged", event_payload: { by_team: false })
    expect(order.reload.status).to eq("acknowledged")
    expect(order.stage).to be_nil
    expect(order.events.map(&:kind)).to eq(%w[requested authorized scheduled scheduled collected resulted acknowledged])
    expect(order.events.second.closed_stage_due_on).to eq(Time.zone.today + 15)
    expect(DomainEvent.where(name: "exam_order.resulted").last.payload)
      .to eq("exam_order_id" => order.id, "source" => "unit", "critical" => false)
  end

  it "recusa transição fora da tabela com o status atual; negar e cancelar exigem motivo" do
    order = open
    expect(step(order, "collected").then { |r| [ r.reason, r.details ] }).to eq([ :invalid_transition, { status: "awaiting_schedule" } ])
    expect(step(order, "authorized").reason).to eq(:invalid_transition)
    expect(step(order, "cancelled", reason: " ").reason).to eq(:reason_required)
    expect(step(order, "cancelled", reason: "Paciente fez em outro serviço")).to be_ok
    expect(step(order, "scheduled").reason).to eq(:invalid_transition)
    expect(order.reload.events.last.reason).to eq("Paciente fez em outro serviço")
    expect(DomainEvent.where(name: "exam_order.cancelled").last.payload).to eq("exam_order_id" => order.id)
  end

  it "escalar é idempotente por motivo (A31), não muda o status e guarda a primeira data" do
    order = open
    step(order, "scheduled"); step(order, "collected"); step(order, "resulted", event_payload: { source: "unit", critical: true })
    first_at = Time.zone.local(2026, 10, 13, 10)
    escalate = ->(reason, now) { ApplicationRecord.transaction { order.lock!; Exams::Escalate.call(order: order, reason: reason, now: now) } }
    outcomes = [ escalate.("overdue", first_at), escalate.("critical", first_at + 1.hour), escalate.("overdue", first_at + 2.hours),
                 escalate.("critical", first_at + 3.hours) ]
    expect(outcomes.map { |r| r.payload[:escalated] }).to eq([ true, true, false, false ])
    expect(order.reload).to have_attributes(status: "resulted", escalated_at: first_at)
    expect(order.events.where(kind: "escalated").pluck(:escalation_reason)).to eq(%w[overdue critical])
    expect(DomainEvent.where(name: "exam_order.escalated").map(&:payload))
      .to contain_exactly(*[ { "exam_order_id" => order.id, "reason" => "overdue" }, { "exam_order_id" => order.id, "reason" => "critical" } ])
  end

  it "trava o pedido por dentro: objeto velho sem trava do chamador não passa por cima do status real (ruling)" do
    order = open
    stale = ExamOrder.find(order.id)
    step(order, "cancelled", reason: "Paciente fez em outro serviço")
    expect(stale.status).to eq("awaiting_schedule")
    expect(described_class.call(order: stale, kind: "scheduled", actor_user: doctor).then { |r| [ r.reason, r.details ] })
      .to eq([ :invalid_transition, { status: "cancelled" } ])
    other = open(sigtap: "0202020380")
    fresh, old = ExamOrder.find(other.id), ExamOrder.find(other.id)
    first_at = Time.zone.local(2026, 10, 13, 10)
    Exams::Escalate.call(order: fresh, reason: "overdue", now: first_at)
    expect(old.escalated_at).to be_nil
    expect(Exams::Escalate.call(order: old, reason: "critical", now: first_at + 1.hour).payload[:escalated]).to be(true)
    expect(other.reload.escalated_at).to eq(first_at)
  end
end
