require "rails_helper"

# Módulo 35b, Task 6 (ADR 0054; contrato §3, Q17): a baixa da dose antirrábica
# e da coleira no razão do 27a pelo FEFO do 35a. 1 un do local
# vector_control_settings.stock_location_id, um lote só; sem local, sem lote ou
# sem saldo, a falta com `source` e `occurred_on` (nunca a recusa); o estorno
# da dose anulada volta ao mesmo lote e local, e a falta aberta da dose é
# conciliada pelo sistema, sem movimento.
RSpec.describe Zoonoses::ApplyStock, type: :model do
  let!(:city) { zoonoses_city! }
  let(:by) { zoonoses_team! }
  let(:vaccine) { zoonoses_product! }
  let(:location) { vector_location! }
  let(:today) { Time.zone.today }

  def dose(**over) = rabies_vaccination!(product: vaccine, **over)
  def deduct(document, kind: "animal_vaccination", product: vaccine)
    described_class.call(document: document, product_id: product.id, kind: kind, by: by, today: today)
  end
  def balance(lot) = Pharmacy::Ledger.balance(location_id: location.id, lot_id: lot.id)

  it "dose baixa 1 un do lote que vence primeiro" do
    vector_stock_location!(location)
    first = vector_lot!(location, product: vaccine, quantity: "3", expires_on: today + 30, lot_number: "A")
    second = vector_lot!(location, product: vaccine, quantity: "5", expires_on: today + 60, lot_number: "B")
    vaccination = dose

    result = deduct(vaccination)
    expect(result).to be_ok
    movement = result.payload.fetch(:movement)
    expect(movement).to have_attributes(kind: "animal_vaccination", stock_location_id: location.id, stock_lot_id: first.id,
                                        quantity: BigDecimal("-1"), vector_product_id: vaccine.id,
                                        rabies_vaccination_id: vaccination.id, recorded_by_user_id: by.id)
    expect([ balance(first), balance(second) ]).to eq([ BigDecimal("2"), BigDecimal("5") ])

    collar_product = zoonoses_product!(use: "collar")
    vector_lot!(location, product: collar_product, quantity: "2")
    collar = collar!(product: collar_product)
    placed = deduct(collar, kind: "collar_placement", product: collar_product).payload.fetch(:movement)
    expect(placed).to have_attributes(kind: "collar_placement", quantity: BigDecimal("-1"), collar_id: collar.id)
    expect(VectorStockShortfall.count).to eq(0)
  end

  it "sem local → falta no_location; sem lote → no_lot; lote zerado → insufficient_balance" do
    without = dose(vaccinated_on: today - 2)
    shortfall = deduct(without).payload.fetch(:shortfall)
    expect(shortfall).to have_attributes(cause: "no_location", stock_location_id: nil, quantity: BigDecimal("1"), source: "vaccination",
                                         rabies_vaccination_id: without.id, vector_inspection_measure_id: nil, collar_id: nil,
                                         occurred_on: today - 2, vector_product_id: vaccine.id, reconciled_at: nil)

    vector_stock_location!(location)
    expect(deduct(dose).payload.fetch(:shortfall)).to have_attributes(cause: "no_lot", stock_location_id: location.id)

    lot = vector_lot!(location, product: vaccine, quantity: "1")
    expect(deduct(dose).payload).to include(:movement)
    expect(balance(lot)).to eq(0)
    expect(deduct(dose).payload.fetch(:shortfall)).to have_attributes(cause: "insufficient_balance", stock_location_id: location.id)

    collar_product = zoonoses_product!(use: "collar")
    collar = collar!(product: collar_product, placed_on: today - 1)
    expect(deduct(collar, kind: "collar_placement", product: collar_product).payload.fetch(:shortfall))
      .to have_attributes(cause: "no_lot", source: "collar", collar_id: collar.id, rabies_vaccination_id: nil, occurred_on: today - 1)

    location.update!(active: false)
    expect(deduct(dose).payload.fetch(:shortfall)).to have_attributes(cause: "no_location", stock_location_id: nil)
    expect(RabiesVaccination.count).to eq(5)
    expect(StockMovement.where(kind: "animal_vaccination").count).to eq(1)
  end

  it "a recusa do Ledger (Insufficient) só volta o savepoint: a falta insufficient_balance, nunca a exceção" do
    vector_stock_location!(location)
    vector_lot!(location, product: vaccine, quantity: "5")
    allow(Pharmacy::Ledger).to receive(:record!).and_raise(Pharmacy::Ledger::Insufficient)
    expect(deduct(dose).payload.fetch(:shortfall)).to have_attributes(cause: "insufficient_balance", stock_location_id: location.id)
    expect(StockMovement.where(kind: "animal_vaccination")).to be_empty
  end

  it "estorno positivo no mesmo lote; estorno de dose com falta concilia pelo sistema, sem movimento" do
    vector_stock_location!(location)
    lot = vector_lot!(location, product: vaccine, quantity: "1")
    applied = dose
    deduct(applied)
    short = dose
    shortfall = deduct(short).payload.fetch(:shortfall)
    location.update!(active: false) # o local desativado depois da baixa recebe o estorno assim mesmo

    reversal = described_class.reverse!(vaccination: applied, by: by)
    expect(reversal).to have_attributes(kind: "animal_vaccination_reversal", stock_lot_id: lot.id, stock_location_id: location.id,
                                        quantity: BigDecimal("1"), rabies_vaccination_id: applied.id, recorded_by_user_id: by.id)
    expect(balance(lot)).to eq(BigDecimal("1"))
    expect(described_class.reverse!(vaccination: applied, by: by)).to be_nil # uma vez só
    expect(StockMovement.where(kind: "animal_vaccination_reversal").count).to eq(1)

    movements = StockMovement.count
    expect(described_class.reverse!(vaccination: short, by: by)).to be_nil
    expect(StockMovement.count).to eq(movements)
    expect(shortfall.reload).to have_attributes(reconciled_by_user_id: nil, reconciliation_note: nil, version: 2)
    expect(shortfall.reconciled_at).to be_present
  end

  it "evento shortfall_recorded só com o id" do
    shortfall = deduct(dose).payload.fetch(:shortfall)
    expect(DomainEvent.where(name: "vector_stock.shortfall_recorded").sole.payload).to eq("vector_stock_shortfall_id" => shortfall.id)
  end
end
