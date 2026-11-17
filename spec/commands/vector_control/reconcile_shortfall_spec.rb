require "rails_helper"

# Módulo 35a, Task 7 (ADR 0054; contrato §4, §17; Q9): a conciliação da falta
# de insumo, pela coordenação ou pelo stock_keeper do local, com nota de
# 10–500 caracteres, uma vez, sem movimento de estoque.
RSpec.describe VectorControl::ReconcileShortfall, type: :model do
  let!(:city) { vector_city! }
  let(:coordinator) { endemic_coordinator! }
  let(:product) { vector_product! }
  let(:location) { vector_location! }
  let(:note) { "lote achado no depósito da UVZ" }

  before do
    allow(Ledi::DeliverJob).to receive(:perform_later)
    vector_stock_location!(location)
  end

  it "nota de 9 → invalid_request path note; repetida → already_reconciled; stock_keeper de outro local → missing_role" do
    shortfall = vector_shortfall!(product: product)
    keeper = vector_keeper!(location)

    short = described_class.call(shortfall: shortfall, note: "123456789", by: keeper)
    expect([ short.reason, short.details ]).to eq([ :invalid_request, { path: "note" } ])
    missing = described_class.call(shortfall: shortfall, note: nil, by: keeper)
    expect([ missing.reason, missing.details ]).to eq([ :invalid_request, { path: "note" } ])
    expect(described_class.call(shortfall: shortfall, note: "x" * 501, by: keeper).reason).to eq(:invalid_request)

    outsider = vector_keeper!(vector_location!)
    expect(described_class.call(shortfall: shortfall, note: note, by: outsider).reason).to eq(:missing_role)

    movements = StockMovement.count
    expect(described_class.call(shortfall: shortfall, note: "  #{note}  ", by: keeper)).to be_ok
    expect(shortfall.reload).to have_attributes(reconciled_by_user_id: keeper.id, reconciliation_note: note, version: 2)
    expect(StockMovement.count).to eq(movements)
    event = DomainEvent.where(name: "vector_stock.shortfall_reconciled").sole
    expect(event.payload).to eq("vector_stock_shortfall_id" => shortfall.id, "user_id" => keeper.id)

    again = described_class.call(shortfall: shortfall, note: "outra nota, diferente da primeira", by: coordinator)
    expect(again.reason).to eq(:already_reconciled)
  end

  it "no_location só a coordenação" do
    vector_stock_location!(nil)
    shortfall = vector_shortfall!(product: product)
    expect(shortfall.cause).to eq("no_location")
    expect(described_class.call(shortfall: shortfall, note: note, by: vector_keeper!(location)).reason).to eq(:missing_role)
    expect(described_class.call(shortfall: shortfall, note: note, by: coordinator)).to be_ok
  end

  it "a nota é cifrada e nunca sai no inspect" do
    shortfall = vector_shortfall!(product: product)
    described_class.call(shortfall: shortfall, note: note, by: coordinator)
    raw = VectorStockShortfall.connection.select_value("SELECT reconciliation_note FROM vector_stock_shortfalls WHERE id = '#{shortfall.id}'")
    expect(raw).not_to include(note)
    expect(shortfall.reload.inspect).not_to include(note)
  end
end
