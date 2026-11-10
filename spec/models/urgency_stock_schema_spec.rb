require "rails_helper"
require Rails.root.join("db/city_migrate/20261110900003_add_urgency_stock_deduction.rb").to_s

# Módulo 32b (ADR 0050; contrato §1, §6 e §12 Q6/Q7/Q10): o movimento
# `administration` no livro do 27a (mesmo caminho do 29, Desvio 7) e as faltas
# de estoque da checagem da UPA (R7).
RSpec.describe "Esquema do estoque da observação da UPA", type: :model do
  let!(:city) do
    pharmacy_city!.tap { |c| Platform::Features.set!(city: c, key: Urgency::Gate::KEY, enabled: true, maintainer: ledi_maintainer!) }
  end
  let(:upa) { create_unit("UPA Estoque", kind: "upa") }
  let(:doctor) { upa_doctor!(upa) }
  let(:link) { ProfessionalLink.find_by!(professional: doctor.professional) }
  let(:location) { unit_location!(upa) }
  let(:keeper) { pharmacy_staff!(location, "stock_keeper") }
  let(:lot) { stocked_lot!(location, item: losartana, quantity: "10", by: keeper) }
  let!(:encounter) do
    CityCatalog.reset_cache!
    e = arrived!(upa)
    classified!(e, color: "yellow", by: upa_nurse!(upa))
    called!(e, by: doctor)
    e.reload
  end

  def sp(&) = ApplicationRecord.transaction(requires_new: true, &)

  def administration!(**over)
    prescription = UrgencyPrescription.create!(urgency_encounter: encounter, version: 1, prescribed_by_user: doctor, professional_link: link,
                                               cbo_code: "225125", prescribed_at: Time.current)
    item = UrgencyPrescriptionItem.create!(urgency_prescription: prescription, position: 1, catalog_item_id: lot.catalog_item_id,
                                           catmat_code: 268_856, dose: "500", dose_unit: "mg", route: "oral", frequency_kind: "interval",
                                           interval_hours: 8, first_dose_at: Time.current, stock_quantity_per_dose: 1, stock_unit: "comprimido")
    UrgencyAdministration.create!({ urgency_prescription_item: item, urgency_encounter: encounter, scheduled_at: Time.current.change(usec: 0),
                                    status: "administered", administered_at: Time.current, recorded_by_user: doctor,
                                    professional_link: link, cbo_code: "225125", recorded_at: Time.current }.merge(over))
  end

  def movement_attrs(**over)
    { stock_location: location, stock_lot: lot, catalog_item_id: lot.catalog_item_id, kind: "administration", quantity: -1,
      recorded_by_user: keeper, recorded_at: Time.current }.merge(over)
  end

  def refused_constraint(name, &block)
    expect { sp(&block) }.to raise_error(ActiveRecord::StatementInvalid, /#{name}/)
  end

  describe "movimento administration" do
    it "a migração espelha as listas de Pharmacy::Catalog" do
      catalog = Pharmacy::Catalog
      expect([ AddUrgencyStockDeduction::MOVEMENT_KINDS, AddUrgencyStockDeduction::POSITIVE_KINDS, AddUrgencyStockDeduction::NEGATIVE_KINDS ])
        .to eq([ catalog::MOVEMENT_KINDS, catalog::POSITIVE_KINDS, catalog::NEGATIVE_KINDS ])
      expect(catalog::MOVEMENT_KINDS).to end_with("administration")
      expect(catalog::NEGATIVE_KINDS).to end_with("administration")
      expect(catalog::POSITIVE_KINDS).not_to include("administration")
    end

    it "um administration negativo com o documento é aceito" do
      administration = administration!
      expect(StockMovement.create!(movement_attrs(urgency_administration: administration))).to be_persisted
    end

    it "administration positivo é recusado (ck_stock_movements_sign)" do
      administration = administration!
      refused_constraint("ck_stock_movements_sign") { StockMovement.create!(movement_attrs(urgency_administration: administration, quantity: 1)) }
    end

    it "administration sem urgency_administration_id é recusado (ck_stock_movements_document)" do
      refused_constraint("ck_stock_movements_document") do
        StockMovement.create!(movement_attrs(stock_entry: StockEntry.create!(stock_location: location, kind: "invoice", document_number: "NF-1", supplier: "D",
                                                                             recorded_by_user: keeper)))
      end
      refused_constraint("ck_stock_movements_document") { StockMovement.create!(movement_attrs) }
    end

    it "dispensing com urgency_administration_id é recusado (ck_stock_movements_document)" do
      administration = administration!
      refused_constraint("ck_stock_movements_document") do
        StockMovement.create!(movement_attrs(kind: "dispensing", urgency_administration: administration))
      end
    end

    it "ck_stock_movements_kind lista administration" do
      definition = ApplicationRecord.connection.select_value("SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'ck_stock_movements_kind'")
      expect(definition).to include("'administration'::text")
    end
  end

  describe "urgency_stock_shortfalls" do
    def shortfall!(administration = administration!, **over)
      UrgencyStockShortfall.create!({ urgency_administration: administration, stock_location: location, catalog_item_id: lot.catalog_item_id,
                                      quantity: 1, cause: "insufficient_balance" }.merge(over))
    end

    def raw(sql) = ApplicationRecord.connection.execute(sql)

    it "nasce aberta; o modelo não vaza nada em inspect/to_s/as_json" do
      shortfall = shortfall!
      expect(shortfall).to be_persisted
      expect(UrgencyStockShortfall.open_shortfalls).to contain_exactly(shortfall)
      expect(shortfall.as_json).to eq("id" => shortfall.id)
      expect(shortfall.inspect).to eq("#<UrgencyStockShortfall id=#{shortfall.id}>")
    end

    it "uma falta por administração (índice único)" do
      administration = administration!
      shortfall!(administration)
      expect { sp { shortfall!(administration) } }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "causa fora da lista é recusada (ck_urgency_stock_shortfalls_cause)" do
      administration = administration!
      refused_constraint("ck_urgency_stock_shortfalls_cause") do
        UrgencyStockShortfall.new(urgency_administration: administration, stock_location: location, catalog_item_id: lot.catalog_item_id,
                                  quantity: 1, cause: "other").save!(validate: false)
      end
    end

    it "quantidade positiva (ck_urgency_stock_shortfalls_quantity)" do
      refused_constraint("ck_urgency_stock_shortfalls_quantity") { shortfall!(administration!, quantity: 0) }
    end

    it "no_location <=> sem local (ck_urgency_stock_shortfalls_location)" do
      refused_constraint("ck_urgency_stock_shortfalls_location") { shortfall!(administration!, cause: "no_location") }
      refused_constraint("ck_urgency_stock_shortfalls_location") { shortfall!(administration!, stock_location: nil) }
      expect(shortfall!(administration!, cause: "no_location", stock_location: nil)).to be_persisted
    end

    it "os três campos da conciliação vêm juntos (ck_urgency_stock_shortfalls_reconciliation)" do
      shortfall = shortfall!
      refused_constraint("ck_urgency_stock_shortfalls_reconciliation") { shortfall.update_columns(reconciled_at: Time.current) }
      refused_constraint("ck_urgency_stock_shortfalls_reconciliation") do
        shortfall.update_columns(reconciled_at: Time.current, reconciled_by_user_id: keeper.id)
      end
    end

    it "a conciliação grava os três campos uma vez e a conciliada nunca muda" do
      shortfall = shortfall!
      shortfall.update!(reconciled_at: Time.current, reconciled_by_user: keeper, reconciliation_note: "Baixa regularizada no inventário")
      expect(shortfall.reload.reconciliation_note).to eq("Baixa regularizada no inventário")
      expect(UrgencyStockShortfall.open_shortfalls).to be_empty
      expect { sp { shortfall.update_columns(reconciliation_note: "Outra nota qualquer aqui") } }
        .to raise_error(ActiveRecord::StatementInvalid, /urgency_stock_shortfalls: reconciled once/)
      expect { sp { shortfall.update_columns(updated_at: Time.current) } }
        .to raise_error(ActiveRecord::StatementInvalid, /urgency_stock_shortfalls: reconciled once/)
    end

    it "a aberta só recebe a conciliação e updated_at" do
      shortfall = shortfall!
      expect { sp { shortfall.update_columns(quantity: 2) } }
        .to raise_error(ActiveRecord::StatementInvalid, /urgency_stock_shortfalls: an open shortfall only receives the reconciliation/)
      expect { sp { shortfall.update_columns(cause: "lot_unavailable") } }
        .to raise_error(ActiveRecord::StatementInvalid, /an open shortfall only receives the reconciliation/)
      expect { sp { shortfall.update_columns(updated_at: Time.current) } }
        .to raise_error(ActiveRecord::StatementInvalid, /an open shortfall only receives the reconciliation/)
    end

    it "a re-cifra da nota passa antes das outras regras, mesmo na conciliada; outra coluna sob a marca é recusada" do
      shortfall = shortfall!
      shortfall.update!(reconciled_at: Time.current, reconciled_by_user: keeper, reconciliation_note: "Baixa regularizada no inventário")
      expect(CityEncryption::CITY_KEYED_TARGETS).to include([ UrgencyStockShortfall, :reconciliation_note ])
      sp do
        raw("SET LOCAL rota.reencrypting = 'on'")
        expect { raw("UPDATE urgency_stock_shortfalls SET reconciliation_note = 'regravado' WHERE id = '#{shortfall.id}'") }.not_to raise_error
      end
      expect { sp { raw("SET LOCAL rota.reencrypting = 'on'"); raw("UPDATE urgency_stock_shortfalls SET quantity = 2 WHERE id = '#{shortfall.id}'") } }
        .to raise_error(ActiveRecord::StatementInvalid, /reconciled once/)
    end

    it "DELETE e TRUNCATE recusados" do
      shortfall = shortfall!
      expect { sp { shortfall.delete } }.to raise_error(ActiveRecord::StatementInvalid, /urgency_stock_shortfalls: DELETE refused/)
      expect { sp { raw("TRUNCATE urgency_stock_shortfalls") } }
        .to raise_error(ActiveRecord::StatementInvalid, /urgency_stock_shortfalls is append-only: TRUNCATE refused/)
    end

    it "a nota conciliada fica cifrada no banco" do
      shortfall = shortfall!
      shortfall.update!(reconciled_at: Time.current, reconciled_by_user: keeper, reconciliation_note: "Baixa regularizada no inventário")
      stored = raw("SELECT reconciliation_note FROM urgency_stock_shortfalls WHERE id = '#{shortfall.id}'").first["reconciliation_note"]
      expect(stored).not_to include("regularizada")
    end
  end

  describe "Pharmacy::Ledger e Pharmacy::Statement" do
    let(:ledger) { Pharmacy::Ledger }

    it "record! grava −1 com o documento da administração" do
      administration = administration!
      movement = ledger.record!(location: location, lot: lot, kind: "administration", quantity: BigDecimal("1"), by: keeper, document: administration)
      expect(movement.quantity).to eq(-1)
      expect(movement.urgency_administration).to eq(administration)
      expect(administration.reload.stock_movement).to eq(movement)
      expect(ledger.balance(location_id: location.id, lot_id: lot.id)).to eq(9)
    end

    it "o saldo que ficaria negativo → Insufficient" do
      administration = administration!
      expect { ledger.record!(location: location, lot: lot, kind: "administration", quantity: BigDecimal("11"), by: keeper, document: administration) }
        .to raise_error(Pharmacy::Ledger::Insufficient)
      expect(StockMovement.where(kind: "administration")).to be_empty
    end

    it "o extrato devolve document { type: urgency_administration, id, number: nil }" do
      administration = administration!
      ledger.record!(location: location, lot: lot, kind: "administration", quantity: BigDecimal("1"), by: keeper, document: administration)
      result = Pharmacy::Statement.call(location: location, lot: lot, limit: 10)
      movement = result[:movements].find { |m| m[:kind] == "administration" }
      expect(movement[:document]).to eq(type: "urgency_administration", id: administration.id, number: nil)
      expect(movement[:quantity]).to eq("-1.00")
    end
  end
end
