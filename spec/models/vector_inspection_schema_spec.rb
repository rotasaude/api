require "rails_helper"
require Rails.root.join("db/city_migrate/20261116900002_add_vector_inspections.rb").to_s

# Módulo 35a (ADR 0054; contrato §1 e §4; plano, Task 3): o banco do boletim e
# o terceiro domínio do estoque. Uma inspeção por visita, com domicílio (A-10);
# depósitos, medidas e amostras com os limites do §3 também no banco; o
# resultado da amostra todo ou nada, corrigido só com nota nova; a falta de
# estoque conciliada uma vez (pelo sistema sem usuário nem nota, W-6); o lote,
# o mínimo, a abertura e o movimento com `vector_product_id` (como o 29 fez
# com o imunobiológico); `vector_application` (−) e o estorno
# `vector_application_reversal` (+, A-1) com a medida por documento.
RSpec.describe "Esquema da inspeção do módulo 35a", type: :model do
  before { vector_city! }

  # Escrita crua que o banco recusa: sem savepoint a recusa aborta a transação do exemplo.
  def refused(pattern = nil, error: ActiveRecord::StatementInvalid, &block)
    expect { ApplicationRecord.transaction(requires_new: true, &block) }.to raise_error(error, pattern)
  end

  # Avaliados antes de qualquer savepoint recusado (que desfaria as linhas).
  let!(:coordinator) { endemic_coordinator! }
  let!(:household) { registry_household! }
  let!(:product) { product!("BTI") }

  def product!(code, unit: "g", charge_size: "0.50", uses: %w[focal perifocal])
    VectorProduct.create!(code: code, name: "Produto #{code}", unit: unit, charge_size: BigDecimal(charge_size), uses: uses)
  end

  # `validate: false` grava sem as validações do modelo (para provar o banco).
  def inspection!(visit: home_visit!(household: household), validate: true, **over)
    record = VectorInspection.new({ home_visit: visit, household_id: visit.household_id || household.id, activity: "li",
                                    work_type: "routine", situation: "worked", educational_action: true }.merge(over))
    record.save!(validate: validate)
    record
  end

  def deposit!(inspection, group: "A1", **counts)
    VectorInspectionDeposit.create!({ vector_inspection_id: inspection.id, group: group, existing: 3, with_water: 2, with_larvae: 1,
                                      eliminated: 1, treated: 1 }.merge(counts))
  end

  def measure!(inspection, method: "focal", product: self.product, charges: "2", quantity: "1.00")
    VectorInspectionMeasure.create!(vector_inspection_id: inspection.id, method: method, vector_product_id: product&.id,
                                    charges: charges && BigDecimal(charges), quantity: quantity && BigDecimal(quantity))
  end

  def sample!(inspection, number: 1, label: "AM-#{SecureRandom.hex(4)}", **over)
    VectorSample.create!({ vector_inspection_id: inspection.id, number: number, deposit_group: "A1", larvae_collected: 5, label: label }.merge(over))
  end

  # Escrita crua (update_all): a recusa não deixa valor sujo no objeto.
  def raw_update(record, **attrs) = record.class.where(id: record.id).update_all(attrs)

  def result(by = vector_lab!, **over)
    { examined_larvae: 5, aegypti_larvae: 3, albopictus_larvae: 1, result_at: Time.current, result_by_user_id: by.id }.merge(over)
  end

  def vector_location!
    unit = create_unit("UVZ #{SecureRandom.hex(2)}", kind: "environmental_surveillance")
    StockLocation.create!(kind: "vector_control", name: "Endemias #{unit.name}", health_unit: unit, updated_by_user: coordinator)
  end

  def vector_lot!(product = self.product, **over)
    StockLot.create!({ item_kind: "vector_control", vector_product_id: product.id, lot_number: "V#{SecureRandom.hex(3).upcase}",
                       expires_on: Time.zone.today + 180, dispensing_unit: product.unit, created_by_user: coordinator }.merge(over))
  end

  def opening!(location, lot, quantity = 10)
    entry = StockEntry.create!(stock_location: location, kind: "opening", recorded_by_user: coordinator)
    Pharmacy::Ledger.record!(location: location, lot: lot, kind: "opening", quantity: quantity, by: coordinator, document: entry)
  end

  def movement_attrs(location, lot, **over)
    { stock_location: location, stock_lot: lot, vector_product_id: lot.vector_product_id, kind: "vector_application", quantity: -1,
      recorded_by_user: coordinator, recorded_at: Time.current }.merge(over)
  end

  it "a migração espelha Pharmacy::Catalog e VectorControl::Catalog; irreversível" do
    catalog = Pharmacy::Catalog
    expect([ AddVectorInspections::MOVEMENT_KINDS, AddVectorInspections::POSITIVE_KINDS, AddVectorInspections::NEGATIVE_KINDS ])
      .to eq([ catalog::MOVEMENT_KINDS, catalog::POSITIVE_KINDS, catalog::NEGATIVE_KINDS ])
    expect(catalog::MOVEMENT_KINDS.last(2)).to eq(%w[vector_application vector_application_reversal])
    expect(catalog::NEGATIVE_KINDS).to end_with("vector_application")
    expect(catalog::POSITIVE_KINDS).to end_with("vector_application_reversal")
    vc = VectorControl::Catalog
    expect([ AddVectorInspections::ACTIVITIES, AddVectorInspections::WORK_TYPES, AddVectorInspections::SITUATIONS,
             AddVectorInspections::DEPOSIT_GROUPS, AddVectorInspections::METHODS, AddVectorInspections::PRODUCT_USES,
             AddVectorInspections::UNITS ])
      .to eq([ vc::ACTIVITIES, vc::WORK_TYPES, vc::SITUATIONS, vc::DEPOSIT_GROUPS, vc::METHODS, vc::PRODUCT_USES, vc::UNITS ])
    expect(AddVectorInspections::SHORTFALL_CAUSES).to eq(VectorStockShortfall::CAUSES)
    expect { AddVectorInspections.new.down }.to raise_error(ActiveRecord::IrreversibleMigration)
  end

  describe "produto" do
    it "código único sem caixa; unidade, carga e usos no domínio" do
      expect { product!("bti") }.to raise_error(ActiveRecord::RecordNotUnique, /idx_vector_products_code/)
      refused(/ck_vector_products_unit/) { product!("X1", unit: "kg") }
      refused(/ck_vector_products_charge_size/) { product!("X2", charge_size: "0") }
      refused(/ck_vector_products_uses/) { product!("X3", uses: []) }
      refused(/ck_vector_products_uses/) { product!("X4", uses: %w[focal mechanical]) }
    end

    it "unidade e carga mudam até o primeiro lote ou medida; depois, só nome, usos e ativo" do
      product.update!(unit: "ml", charge_size: BigDecimal("0.75"))
      vector_lot!(product.reload)
      refused(/vector_products: unit and charge_size are fixed once the product is in use/) { raw_update(product, unit: "g") }
      refused(/vector_products: unit and charge_size are fixed once the product is in use/) { raw_update(product, charge_size: 1) }
      expect { product.update!(name: "Larvicida", uses: %w[focal], active: false) }.not_to raise_error

      other = product!("TEM")
      measure!(inspection!, product: other)
      refused(/fixed once the product is in use/) { raw_update(other, charge_size: 2) }
    end
  end

  describe "inspeção, depósitos e medidas" do
    it "uma inspeção por visita; domicílio obrigatório (A-10); domínios e horários juntos" do
      visit = home_visit!(household: household)
      inspection!(visit: visit)
      expect { inspection!(visit: visit) }.to raise_error(ActiveRecord::RecordNotUnique, /idx_vector_inspections_visit/)
      refused(error: ActiveRecord::NotNullViolation) { inspection!(household_id: nil, validate: false) }
      refused(/ck_vector_inspections_activity/) { inspection!(activity: "xx") }
      refused(/ck_vector_inspections_work_type/) { inspection!(work_type: "xx") }
      refused(/ck_vector_inspections_situation/) { inspection!(situation: "absent") }
      refused(/ck_vector_inspections_times/) { inspection!(entered_at: Time.current) }
      expect { inspection!(entered_at: 1.hour.ago, left_at: Time.current) }.not_to raise_error
    end

    it "depósito com larva > com água → CHECK; contagens 0–999; um por grupo" do
      inspection = inspection!
      refused(/ck_vector_inspection_deposits_counts/) { deposit!(inspection, with_water: 1, with_larvae: 2) }
      refused(/ck_vector_inspection_deposits_counts/) { deposit!(inspection, existing: 1, with_water: 2, with_larvae: 0, treated: 0) }
      refused(/ck_vector_inspection_deposits_counts/) { deposit!(inspection, existing: 1, with_water: 1, eliminated: 2) }
      refused(/ck_vector_inspection_deposits_counts/) { deposit!(inspection, treated: 3) }
      refused(/ck_vector_inspection_deposits_range/) { deposit!(inspection, existing: 1000) }
      refused(/ck_vector_inspection_deposits_range/) { deposit!(inspection, eliminated: -1) }
      refused(/ck_vector_inspection_deposits_group/) { deposit!(inspection, group: "F") }
      deposit!(inspection)
      expect { deposit!(inspection) }.to raise_error(ActiveRecord::RecordNotUnique, /idx_vector_inspection_deposits_group/)
    end

    it "medida mecânica sem produto nem cargas; focal sem produto → CHECK" do
      inspection = inspection!
      expect(measure!(inspection, method: "mechanical", product: nil, charges: nil, quantity: nil)).to be_persisted
      refused(/ck_vector_inspection_measures_product/) { measure!(inspection, product: nil, charges: nil, quantity: nil) }
      refused(/ck_vector_inspection_measures_product/) { measure!(inspection, method: "mechanical") }
      refused(/ck_vector_inspection_measures_product/) { measure!(inspection, quantity: nil) }
      refused(/ck_vector_inspection_measures_charges/) { measure!(inspection, charges: "0") }
      refused(/ck_vector_inspection_measures_charges/) { measure!(inspection, charges: "999.01") }
      refused(/ck_vector_inspection_measures_quantity/) { measure!(inspection, quantity: "0") }
      refused(/ck_vector_inspection_measures_method/) { measure!(inspection, method: "ubv") }
      expect(measure!(inspection, charges: "999")).to be_persisted
    end

    it "duas medidas mecânicas na mesma inspeção → RecordNotUnique (NULLS NOT DISTINCT)" do
      inspection = inspection!
      measure!(inspection, method: "mechanical", product: nil, charges: nil, quantity: nil)
      expect { measure!(inspection, method: "mechanical", product: nil, charges: nil, quantity: nil) }
        .to raise_error(ActiveRecord::RecordNotUnique, /idx_vector_inspection_measures_key/)
      measure!(inspection)
      expect { measure!(inspection) }.to raise_error(ActiveRecord::RecordNotUnique, /idx_vector_inspection_measures_key/)
      expect { measure!(inspection, method: "perifocal") }.not_to raise_error
    end

    it "inspeção, depósitos e medidas são só acréscimo" do
      inspection = inspection!
      rows = [ inspection, deposit!(inspection), measure!(inspection) ]
      rows.each do |row|
        refused(/#{row.class.table_name} is append-only: UPDATE refused/) { row.update_columns(created_at: 1.day.ago) }
        refused(/#{row.class.table_name} is append-only: DELETE refused/) { row.delete }
      end
    end

    it "valid_inspections deixa de fora a visita retirada" do
      kept = inspection!
      gone = inspection!
      gone.home_visit.update_columns(withdrawn_at: Time.current, withdrawn_by_user_id: gone.home_visit.recorded_by_user_id,
                                     withdrawal_reason: "Registrada no domicílio errado")
      expect(VectorInspection.valid_inspections).to contain_exactly(kept)
    end

    it "o último trabalho do perfil aponta para uma inspeção que existe (FK da 900002)" do
      profile = vector_profile!(household, block: nil)
      refused(/fk_rails/, error: ActiveRecord::InvalidForeignKey) { profile.update_columns(last_inspection_id: SecureRandom.uuid) }
      inspection = inspection!
      expect { profile.update!(last_inspection_id: inspection.id, last_worked_on: Time.zone.today, last_situation: "worked") }.not_to raise_error
    end
  end

  describe "amostras" do
    it "etiqueta repetida → RecordNotUnique; número 1–99 único na inspeção; larvas 1–10" do
      inspection = inspection!
      sample!(inspection, label: "AM-1")
      expect { sample!(inspection!, label: "AM-1") }.to raise_error(ActiveRecord::RecordNotUnique, /idx_vector_samples_label/)
      expect { sample!(inspection) }.to raise_error(ActiveRecord::RecordNotUnique, /idx_vector_samples_number/)
      refused(/ck_vector_samples_number/) { sample!(inspection, number: 100) }
      refused(/ck_vector_samples_larvae/) { sample!(inspection, number: 2, larvae_collected: 11) }
      refused(/ck_vector_samples_larvae/) { sample!(inspection, number: 2, larvae_collected: 0) }
      refused(/ck_vector_samples_deposit_group/) { sample!(inspection, number: 2, deposit_group: "Z") }
    end

    it "resultado parcial → CHECK; examinadas ≤ coletadas; espécies ≤ examinadas" do
      sample = sample!(inspection!)
      refused(/ck_vector_samples_result/) { raw_update(sample, examined_larvae: 5) }
      refused(/ck_vector_samples_result/) { raw_update(sample, **result(result_by_user_id: nil)) }
      refused(/ck_vector_samples_examined/) { raw_update(sample, **result(examined_larvae: 6)) }
      refused(/ck_vector_samples_species/) { raw_update(sample, **result(aegypti_larvae: 4, albopictus_larvae: 2)) }
      expect { sample.update!(result) }.not_to raise_error
    end

    it "corrigir resultado sem nota → recusado pelo trigger; com nota nova passa; nada além do resultado muda" do
      sample = sample!(inspection!)
      refused(/vector_samples: the first result has no note/) do
        VectorSample.find(sample.id).update!(result(result_note: "Recontagem feita no laboratório"))
      end
      sample.update!(result)
      refused(/vector_samples: correcting a result needs a new note/) { VectorSample.find(sample.id).update!(aegypti_larvae: 2) }
      refused(/vector_samples: the result is never cleared/) do
        raw_update(sample, examined_larvae: nil, aegypti_larvae: nil, albopictus_larvae: nil, result_at: nil, result_by_user_id: nil)
      end
      refused(/vector_samples: only the result changes/) { raw_update(sample, label: "AM-OUTRA") }
      sample.reload.update!(aegypti_larvae: 2, result_note: "Recontagem feita no laboratório")
      expect(sample.reload).to have_attributes(aegypti_larvae: 2, result_note: "Recontagem feita no laboratório")
      refused(/vector_samples: correcting a result needs a new note/) { raw_update(sample, albopictus_larvae: 0) }
      expect { CityEncryption.allowing_reencryption { sample.encrypt } }.not_to raise_error
      refused(/vector_samples: DELETE refused/) { sample.delete }
      expect(sample.inspect).to eq("#<VectorSample id=#{sample.id} label=#{sample.label}>")
      expect(sample.inspect).not_to include("Recontagem")
    end
  end

  describe "falta de estoque" do
    def shortfall!(cause: "insufficient_balance", location: vector_location!, validate: true, **over)
      record = VectorStockShortfall.new({ vector_inspection_measure: measure!(inspection!), stock_location: location, vector_product: product,
                                          quantity: BigDecimal("1.00"), cause: cause }.merge(over))
      record.save!(validate: validate)
      record
    end

    it "falta conciliada pelo sistema sem usuário nem nota passa; com usuário sem nota → CHECK" do
      expect { shortfall!(reconciled_at: Time.current) }.not_to raise_error
      refused(/ck_vector_stock_shortfalls_reconciliation/) { shortfall!(reconciled_at: Time.current, reconciled_by_user: coordinator) }
      refused(/ck_vector_stock_shortfalls_reconciliation/) { shortfall!(reconciliation_note: "Conciliada na contagem do mês") }
      refused(/ck_vector_stock_shortfalls_reconciliation/) do
        shortfall!(reconciled_by_user: coordinator, reconciliation_note: "Conciliada na contagem do mês")
      end
      expect { shortfall!(reconciled_at: Time.current, reconciled_by_user: coordinator, reconciliation_note: "Conciliada na contagem do mês") }
        .not_to raise_error
    end

    it "sem local ⇔ no_location; causa no domínio; quantidade positiva; uma por medida" do
      refused(/ck_vector_stock_shortfalls_location/) { shortfall!(cause: "no_location") }
      refused(/ck_vector_stock_shortfalls_location/) { shortfall!(location: nil) }
      expect { shortfall!(cause: "no_location", location: nil) }.not_to raise_error
      refused(/ck_vector_stock_shortfalls_cause/) { shortfall!(cause: "lot_unavailable", validate: false) }
      refused(/ck_vector_stock_shortfalls_quantity/) { shortfall!(quantity: 0) }
      first = shortfall!(cause: "no_lot")
      expect { VectorStockShortfall.create!(first.attributes.except("id", "created_at", "updated_at")) }
        .to raise_error(ActiveRecord::RecordNotUnique, /idx_vector_stock_shortfalls_measure/)
    end

    it "a aberta só recebe a conciliação, uma vez; nunca some; re-cifra passa" do
      shortfall = shortfall!
      refused(/vector_stock_shortfalls: an open shortfall only receives the reconciliation/) { raw_update(shortfall, quantity: 2) }
      shortfall.update!(reconciled_at: Time.current, reconciled_by_user: coordinator, reconciliation_note: "Conciliada na contagem do mês")
      refused(/vector_stock_shortfalls: reconciled once/) { shortfall.update!(reconciliation_note: "Outra nota qualquer aqui") }
      refused(/vector_stock_shortfalls: reconciled once/) { shortfall.encrypt }
      expect { CityEncryption.allowing_reencryption { shortfall.encrypt } }.not_to raise_error
      refused(/vector_stock_shortfalls: DELETE refused/) { shortfall.delete }
      expect(shortfall.inspect).to eq("#<VectorStockShortfall id=#{shortfall.id}>")
    end
  end

  describe "estoque: o terceiro domínio" do
    it "local vector_control sem unidade → CHECK" do
      refused(/ck_stock_locations_unit/) do
        StockLocation.create!(kind: "vector_control", name: "Endemias sem unidade", updated_by_user: coordinator)
      end
      location = vector_location!
      expect(location).to be_vector_control
      refused(/ck_stock_locations_kind/) { location.update_columns(kind: "lab") }
    end

    it "lote vector_control com catalog_item_id → CHECK; produto só no lote vector_control; número único por produto" do
      # O catálogo CATMAT é da plataforma (catalog_item_id sem FK).
      item = Struct.new(:id, :catmat_code).new(SecureRandom.uuid, 268_856)
      refused(/ck_stock_lots_item/) { vector_lot!(catalog_item_id: item.id, catmat_code: item.catmat_code) }
      refused(/ck_stock_lots_item/) { vector_lot!(immunobiological_code: "86") }
      refused(/ck_stock_lots_item/) { vector_lot!(manufacturer_key: "fiocruz") }
      refused(/ck_stock_lots_item/) { vector_lot!(vector_product_id: nil) }
      refused(/ck_stock_lots_item/) { vector_lot!(item_kind: "medication", catalog_item_id: item.id, catmat_code: item.catmat_code) }
      lot = vector_lot!(lot_number: "BTI-01")
      expect(lot).to be_vector_control
      expect { vector_lot!(lot_number: "BTI-01") }.to raise_error(ActiveRecord::RecordNotUnique, /idx_stock_lots_vector_product_number/)
      expect { vector_lot!(product!("TEM"), lot_number: "BTI-01") }.not_to raise_error
    end

    it "mínimo e abertura com uma chave de item só, uma vez por (local, produto)" do
      location = vector_location!
      StockMinimum.create!(stock_location: location, vector_product_id: product.id, minimum: 5, updated_by_user: coordinator)
      expect { StockMinimum.create!(stock_location: location, vector_product_id: product.id, minimum: 6, updated_by_user: coordinator) }
        .to raise_error(ActiveRecord::RecordNotUnique, /idx_stock_minimums_vector_product/)
      refused(/ck_stock_minimums_item/) do
        StockMinimum.create!(stock_location: location, vector_product_id: product!("TEM").id, immunobiological_code: "86", minimum: 1,
                             updated_by_user: coordinator)
      end
      entry = StockEntry.create!(stock_location: location, kind: "opening", recorded_by_user: coordinator)
      StockOpening.create!(stock_location: location, vector_product_id: product.id, stock_entry: entry)
      expect { StockOpening.create!(stock_location: location, vector_product_id: product.id, stock_entry: entry) }
        .to raise_error(ActiveRecord::RecordNotUnique, /idx_stock_openings_vector_product_once/)
      refused(/ck_stock_openings_item/) { StockOpening.create!(stock_location: location, stock_entry: entry) }
    end

    it "movimento vector_application positivo → CHECK; vector_application_reversal negativo → CHECK; vector_application sem medida → CHECK" do
      location = vector_location!
      lot = vector_lot!
      opening!(location, lot)
      measure = measure!(inspection!)
      refused(/ck_stock_movements_sign/) { StockMovement.create!(movement_attrs(location, lot, vector_inspection_measure: measure, quantity: 1)) }
      refused(/ck_stock_movements_sign/) do
        StockMovement.create!(movement_attrs(location, lot, kind: "vector_application_reversal", vector_inspection_measure: measure))
      end
      refused(/ck_stock_movements_document/) { StockMovement.create!(movement_attrs(location, lot)) }
      refused(/ck_stock_movements_document/) do
        StockMovement.create!(movement_attrs(location, lot, kind: "loss", quantity: -1, reason: "Embalagem rompida no transporte",
                                                            vector_inspection_measure: measure))
      end
      refused(/ck_stock_movements_item/) do
        StockMovement.create!(movement_attrs(location, lot, vector_inspection_measure: measure, immunobiological_code: "86"))
      end
      StockMovement.create!(movement_attrs(location, lot, vector_inspection_measure: measure))
      StockMovement.create!(movement_attrs(location, lot, kind: "vector_application_reversal", quantity: 1, vector_inspection_measure: measure))
      expect(balance_of(location, lot)).to eq(10)
    end

    it "movimento com vector_product_id diferente do lote → trigger" do
      location = vector_location!
      lot = vector_lot!
      refused(/stock_movements: vector_product_id differs from the lot/) do
        entry = StockEntry.create!(stock_location: location, kind: "opening", recorded_by_user: coordinator)
        StockMovement.create!(movement_attrs(location, lot, kind: "opening", quantity: 10, stock_entry: entry, vector_product_id: product!("TEM").id))
      end
    end

    it "Pharmacy::Ledger.record! grava vector_application de lote de produto e copia o vector_product_id" do
      location = vector_location!
      lot = vector_lot!
      opening!(location, lot, BigDecimal("10"))
      measure = measure!(inspection!)
      movement = Pharmacy::Ledger.record!(location: location, lot: lot, kind: "vector_application", quantity: BigDecimal("1.25"),
                                          by: coordinator, document: measure)
      expect(movement.reload).to have_attributes(kind: "vector_application", quantity: BigDecimal("-1.25"), vector_product_id: product.id,
                                                 catalog_item_id: nil, immunobiological_code: nil, vector_inspection_measure_id: measure.id)
      reversal = Pharmacy::Ledger.record!(location: location, lot: lot, kind: "vector_application_reversal", quantity: BigDecimal("1.25"),
                                          by: coordinator, document: measure)
      expect(reversal.quantity).to eq(BigDecimal("1.25"))
      expect(Pharmacy::Ledger.balance(location_id: location.id, lot_id: lot.id)).to eq(BigDecimal("10"))
      expect { Pharmacy::Ledger.record!(location: location, lot: lot, kind: "vector_application", quantity: 11, by: coordinator, document: measure) }
        .to raise_error(Pharmacy::Ledger::Insufficient)
    end
  end

  it "nenhuma das seis aceita DELETE nem TRUNCATE" do
    inspection = inspection!
    measure = measure!(inspection)
    rows = [ product, inspection, deposit!(inspection), measure, sample!(inspection),
             VectorStockShortfall.create!(vector_inspection_measure: measure, vector_product: product, quantity: 1, cause: "no_location") ]
    expect(rows.map { |row| row.class.table_name }).to match_array(AddVectorInspections::TABLES)
    rows.each { |row| refused(/#{row.class.table_name}/) { row.delete } }
    AddVectorInspections::TABLES.each do |table|
      refused(/#{table} is append-only/) { VectorProduct.connection.execute("TRUNCATE #{table} CASCADE") }
    end
  end
end
