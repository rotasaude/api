require "rails_helper"

# Módulo 25: a fila usa o MESMO instante `now:` no filtro `overdue=true` e na
# ordenação/campo de atraso (correção da revisão da Task 11).
RSpec.describe Surveillance::Queue do
  before { surveillance_city! }

  it "overdue=true avalia o prazo contra o now: recebido, não contra o relógio" do
    notification = notification!(patient: surveillance_patient!(1), disease_code: "dengue") # semanal: vence em 7 dias
    due = notification.due_at

    early = described_class.call(filters: { "overdue" => "true" }, limit: 10, now: due - 1.minute)
    expect(early.payload[:rows]).to eq([])

    late = described_class.call(filters: { "overdue" => "true" }, limit: 10, now: due + 1.minute)
    expect(late.payload[:rows].map(&:id)).to eq([ notification.id ])
    expect(late.payload[:rows].first.q_overdue).to be(true)
  end
end
