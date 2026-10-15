require "rails_helper"

# Desvio 3 e 16: só o laboratório reabre a coleta; cancelar exame com item
# pendente cancela o item; com item digitado, 409. Ordem de trava (E2): Steps.cancel
# trava requisição → item → pedido, a mesma de Lab::Release (Task 17).
RSpec.describe Exams::Steps do
  before { lab_city! }

  let(:provider) { lab_provider! }
  let(:exam) { lab_exam!(provider: provider) }
  let(:req) { open_requisition!(provider: provider, exams: [ exam ]) }
  let(:item) { req.items.first }
  let(:order) { item.exam_order }
  let(:doctor) { order.requester_user }

  it "a unidade não reagenda exame coletado" do
    Exams::Transition.call(order: order, kind: "collected", actor_user: doctor)
    result = described_class.schedule(order: order, actor_user: doctor,
                                      params: { provider_id: provider.id, scheduled_at: 1.day.from_now.iso8601, scheduled_place: "X" })
    expect([ result.reason, result.details[:status] ]).to eq([ :invalid_transition, "collected" ])
  end

  it "cancelar com item pendente cancela o item; com item digitado, 409" do
    expect(described_class.cancel(order: order, reason: "Desistência", actor_user: doctor)).to be_ok
    expect(item.reload.status).to eq("cancelled")
    other = open_requisition!(provider: provider, exams: [ exam ]).items.first
    other.update!(status: "typed")
    expect(described_class.cancel(order: other.exam_order, reason: "Desistência", actor_user: doctor).reason).to eq(:invalid_transition)
  end
end

