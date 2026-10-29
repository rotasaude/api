require "rails_helper"

# Módulo 27a (ADR 0045): o livro de movimentos. O saldo é a soma dos
# movimentos por (local, lote); a escrita pressupõe a trava dos lotes
# (FOR UPDATE, por id) e o trigger segura o que a conta da aplicação deixar.
RSpec.describe Pharmacy::Ledger do
  before { pharmacy_city! }
  let(:unit) { unit_location! }
  let(:keeper) { pharmacy_staff!(unit, "stock_keeper") }
  let(:lot) { stocked_lot!(unit, item: losartana, quantity: "10", by: keeper) }

  def dispensation_item!(lot, quantity: 4)
    patient = registry_patient!
    external = ExternalPrescription.create!(patient: patient, stock_location: unit, prescriber_name: "Dra. Beltrana", council: "CRM",
                                            council_state: "PR", council_number: "12345", issued_on: Date.current, recorded_by_user: keeper)
    prescribed = ExternalPrescriptionItem.create!(external_prescription: external, position: 1, catalog_item_id: lot.catalog_item_id,
                                                  catmat_code: lot.catmat_code, quantity: quantity, quantity_unit: "comprimido",
                                                  dosage_instructions: "1 comprimido ao dia")
    dispensation = Dispensation.create!(stock_location: unit, patient: patient, external_prescription: external, dispensed_by_user: keeper,
                                        dispensed_by_role: "pharmacist", dispensed_at: Time.current)
    DispensationItem.create!(dispensation: dispensation, external_prescription_item: prescribed, catalog_item_id: lot.catalog_item_id,
                             stock_lot: lot, quantity: quantity)
  end

  def adjustment!(lot, kind: "loss", quantity: -7, status: "applied", counted: nil)
    StockAdjustment.create!(stock_location: unit, stock_lot: lot, kind: kind, status: status, quantity: quantity, counted_quantity: counted,
                            balance_at_request: balance_of(unit, lot), reason: "Frascos quebrados no transporte", requested_by_user: keeper)
  end

  def entry! = StockEntry.create!(stock_location: unit, kind: "invoice", document_number: "NF-#{SecureRandom.hex(2)}", supplier: "Distribuidora", recorded_by_user: keeper)

  # SQL emitido pelo bloco; o subscriber sai mesmo se o bloco falhar.
  def sql_of
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| statements << payload[:sql] }
    yield
    statements
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  def record!(kind:, quantity:, document:, **over)
    described_class.record!(**{ location: unit, lot: lot, kind: kind, quantity: BigDecimal(quantity), by: keeper, document: document }.merge(over))
  end

  describe ".record!" do
    it "dispensação grava o sinal do tipo e o saldo cai" do
      movement = record!(kind: "dispensing", quantity: "4", document: dispensation_item!(lot))
      expect(movement).to be_persisted
      expect(movement.quantity).to eq(-4)
      expect(movement.kind).to eq("dispensing")
      expect(movement.dispensation_item).to be_present
      expect(described_class.balance(location_id: unit.id, lot_id: lot.id)).to eq(6)
    end

    it "grava o item do catálogo do lote, o autor e a hora pedida" do
      at = Time.zone.parse("2026-10-20 10:30")
      movement = record!(kind: "receipt", quantity: "5", document: entry!, at: at)
      expect(movement.catalog_item_id).to eq(lot.catalog_item_id)
      expect(movement.recorded_by_user).to eq(keeper)
      expect(movement.recorded_at).to eq(at)
    end

    it "recorded_at é a hora do negócio; created_at é do Rails (a hora da gravação)" do
      at = Time.zone.parse("2026-10-20 10:30")
      movement = record!(kind: "receipt", quantity: "5", document: entry!, at: at)
      expect(movement.recorded_at).to eq(at)
      expect(movement.created_at).to be_within(1.minute).of(Time.current)
      expect(movement.created_at).not_to eq(at)
    end

    it "tipos positivos somam e os negativos subtraem" do
      record!(kind: "donation", quantity: "2.50", document: entry!)
      record!(kind: "loss", quantity: "7", document: adjustment!(lot), reason: "Frascos quebrados no transporte")
      expect(described_class.balance(location_id: unit.id, lot_id: lot.id)).to eq(BigDecimal("5.5"))
    end

    it "perda maior que o saldo levanta Insufficient com o lote e nada é gravado" do
      record!(kind: "dispensing", quantity: "4", document: dispensation_item!(lot))
      before_count = StockMovement.count
      error = nil
      begin
        record!(kind: "loss", quantity: "7", document: adjustment!(lot), reason: "Frascos quebrados no transporte")
      rescue described_class::Insufficient => e
        error = e
      end
      expect(error).to be_a(described_class::Insufficient)
      expect(error.lot_id).to eq(lot.id)
      expect(error.message).not_to include(lot.lot_number)
      expect(StockMovement.count).to eq(before_count)
      expect(described_class.balance(location_id: unit.id, lot_id: lot.id)).to eq(6)
    end

    it "saldo exatamente zerado passa" do
      record!(kind: "loss", quantity: "10", document: adjustment!(lot, quantity: -10), reason: "Frascos quebrados no transporte")
      expect(described_class.balance(location_id: unit.id, lot_id: lot.id)).to eq(0)
    end

    it "com a conta da aplicação enganada (saldo simulado em 100), o trigger recusa e ainda vira Insufficient" do
      record!(kind: "dispensing", quantity: "4", document: dispensation_item!(lot))
      adjustment = adjustment!(lot)
      allow(described_class).to receive(:balance).and_return(BigDecimal("100"))
      # Transação juntável, como a do comando: sem o savepoint do record!, a
      # recusa do trigger deixaria esta transação abortada para o resto.
      ApplicationRecord.transaction(requires_new: true) do
        expect { record!(kind: "loss", quantity: "7", document: adjustment, reason: "Frascos quebrados no transporte") }
          .to raise_error(described_class::Insufficient) { |e| expect(e.lot_id).to eq(lot.id) }
        allow(described_class).to receive(:balance).and_call_original
        expect(described_class.balance(location_id: unit.id, lot_id: lot.id)).to eq(6)
        record!(kind: "receipt", quantity: "1", document: entry!)
      end
      expect(described_class.balance(location_id: unit.id, lot_id: lot.id)).to eq(7)
    end

    it "ajuste leva o sinal que vem; nos demais tipos o sinal vem do tipo" do
      record!(kind: "adjustment", quantity: "-3", document: adjustment!(lot, kind: "adjustment", quantity: -3, status: "applied", counted: 7),
              reason: "Contagem do inventário de outubro")
      expect(described_class.balance(location_id: unit.id, lot_id: lot.id)).to eq(7)
      record!(kind: "adjustment", quantity: "2", document: adjustment!(lot, kind: "adjustment", quantity: 2, status: "applied", counted: 9),
              reason: "Contagem do inventário de outubro")
      expect(described_class.balance(location_id: unit.id, lot_id: lot.id)).to eq(9)
    end

    it "quantidade que não é positiva (fora o ajuste), zerada ou com 3 casas é erro de programação" do
      entry = entry!
      expect { record!(kind: "receipt", quantity: "-1", document: entry) }.to raise_error(ArgumentError)
      expect { record!(kind: "receipt", quantity: "0", document: entry) }.to raise_error(ArgumentError)
      expect { record!(kind: "receipt", quantity: "1.005", document: entry) }.to raise_error(ArgumentError)
      expect { record!(kind: "adjustment", quantity: "0", document: adjustment!(lot, kind: "adjustment", quantity: 1, counted: 11), reason: "Contagem zerada") }
        .to raise_error(ArgumentError)
      expect { record!(kind: "borrowing", quantity: "1", document: entry) }.to raise_error(ArgumentError)
      expect { record!(kind: "receipt", quantity: "1", document: Object.new) }.to raise_error(ArgumentError)
    end

    it "embalagem e motivo vão para o movimento (motivo cifrado, sem vazar no inspect)" do
      movement = record!(kind: "receipt", quantity: "30", document: entry!, package: { units_per_package: 10, packages: 3 })
      expect([ movement.package_units, movement.packages ]).to eq([ 10, 3 ])
      loss = record!(kind: "loss", quantity: "1", document: adjustment!(lot, quantity: -1), reason: "Frascos quebrados no transporte")
      expect(loss.reload.reason).to eq("Frascos quebrados no transporte")
      expect(loss.inspect).not_to include("Frascos")
    end

    it "movimento do tipo que exige motivo sem motivo é recusado pelo banco" do
      expect { record!(kind: "loss", quantity: "1", document: adjustment!(lot, quantity: -1)) }
        .to raise_error(ActiveRecord::StatementInvalid, /ck_stock_movements_reason/)
    end
  end

  describe ".balance e .balances" do
    it "o saldo é por local e por lote" do
      other_unit = unit_location!
      expect(described_class.balance(location_id: unit.id, lot_id: lot.id)).to eq(10)
      expect(described_class.balance(location_id: other_unit.id, lot_id: lot.id)).to eq(0)
      expect(described_class.balance(location_id: unit.id, lot_id: lot.id)).to be_a(BigDecimal)
    end

    it "balances devolve 0 para lote sem movimento e só do local pedido" do
      empty = StockLot.create!(catalog_item_id: losartana.id, catmat_code: 268_856, lot_number: "SEM-MOV", expires_on: Date.current + 90,
                               dispensing_unit: "comprimido", created_by_user: keeper)
      second = stocked_lot!(unit, item: amoxicilina, quantity: "3.5", by: keeper)
      other_unit = unit_location!
      stocked_lot!(other_unit, item: amoxicilina, quantity: "99", lot_number: second.lot_number, expires_on: second.expires_on, by: keeper)
      result = described_class.balances(location_id: unit.id, lot_ids: [ lot.id, empty.id, second.id ])
      expect(result).to eq(lot.id => 10, empty.id => 0, second.id => BigDecimal("3.5"))
      expect(result.values).to all(be_a(BigDecimal))
      expect(described_class.balances(location_id: unit.id, lot_ids: [])).to eq({})
    end
  end

  describe ".lock_lots!" do
    it "trava por id, em ordem, qualquer que seja a ordem pedida, e devolve { id => lote }" do
      lots = Array.new(3) { |i| stocked_lot!(unit, item: losartana, quantity: "1", lot_number: "ORD#{i}", by: keeper) }
      requested = lots.map(&:id).sort.reverse + [ lots.first.id ]
      locked = nil
      sql = sql_of { locked = described_class.lock_lots!(requested) }
      expect(locked.keys).to match_array(lots.map(&:id))
      expect(locked.values).to all(be_a(StockLot))
      select = sql.find { |s| s.include?("FROM \"stock_lots\"") }
      expect(select).to match(/ORDER BY "stock_lots"\."id" ASC FOR UPDATE\z/)
      expect(locked.keys).to eq(lots.map(&:id).sort)
    end

    it "lote que não existe fica de fora" do
      expect(described_class.lock_lots!([ lot.id, SecureRandom.uuid ]).keys).to eq([ lot.id ])
      expect(described_class.lock_lots!([])).to eq({})
    end
  end

  describe ".lock_location!" do
    it "local ativo: devolve o local, com FOR SHARE" do
      locked = nil
      statements = sql_of { locked = described_class.lock_location!(unit.id) }
      expect(locked).to eq(unit)
      expect(statements.grep(/FROM "stock_locations".*FOR SHARE/)).not_to be_empty
      expect(statements.grep(/FROM "health_units".*FOR SHARE/)).not_to be_empty
    end

    it "o central não trava unidade nenhuma" do
      central = central_location!
      expect(described_class.lock_location!(central.id)).to eq(central)
    end

    it "local inativo levanta Inactive" do
      unit.update!(active: false)
      expect { described_class.lock_location!(unit.id) }.to raise_error(described_class::Inactive)
    end

    it "local de unidade cuja unidade foi desativada levanta Inactive" do
      unit.health_unit.update!(active: false)
      expect(unit.reload.active).to be(true)
      expect { described_class.lock_location!(unit.id) }.to raise_error(described_class::Inactive)
    end

    it "id que não existe levanta Inactive" do
      expect { described_class.lock_location!(SecureRandom.uuid) }.to raise_error(described_class::Inactive)
    end
  end
end
