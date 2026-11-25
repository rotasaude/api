require "rails_helper"
require Rails.root.join("db/city_migrate/20261125900002_add_stock_external_exits.rb").to_s

# Módulo 27b (Task 9; Q8, Q10, Q11): a saída externa (tabela, itens e o
# movimento external_exit) e a base do desfazer da abertura (opening_reversal,
# stock_openings.reverted_at e os únicos parciais). O banco segura o formato; os
# triggers seguram o que o código não pode quebrar.
RSpec.describe "Esquema da saída externa e do desfazer da abertura (módulo 27b)", type: :model do
  before { pharmacy_city! }
  let(:keeper) { pharmacy_admin! }
  let(:central) { central_location! }
  let(:lot) { stocked_lot!(central, item: losartana, quantity: "50", lot_number: "SX-1") }

  def exit!(**over)
    StockExternalExit.create!({ stock_location: central, exit_type: "S-D", destination_kind: "cnpj", destination_code: "12ABC34501DE35",
                                reason: "Doação à entidade filantrópica", recorded_by_user: keeper, recorded_at: Time.current }.merge(over))
  end

  def item!(external, quantity: 5, stock_lot: lot)
    StockExternalExitItem.create!(stock_external_exit: external, stock_lot: stock_lot, quantity: quantity)
  end

  def movement!(**over)
    StockMovement.create!({ stock_location: central, stock_lot: lot, catalog_item_id: lot.catalog_item_id, kind: "external_exit", quantity: -5,
                            recorded_by_user: keeper, recorded_at: Time.current }.merge(over))
  end

  def refused(pattern = nil, &block)
    expect { ApplicationRecord.transaction(requires_new: true, &block) }.to raise_error(ActiveRecord::StatementInvalid, pattern)
  end

  it "a migração espelha Pharmacy::Catalog e Bnafar::Catalog; irreversível" do
    catalog = Pharmacy::Catalog
    expect([ AddStockExternalExits::MOVEMENT_KINDS, AddStockExternalExits::POSITIVE_KINDS, AddStockExternalExits::NEGATIVE_KINDS,
             AddStockExternalExits::EXIT_TYPES ])
      .to eq([ catalog::MOVEMENT_KINDS, catalog::POSITIVE_KINDS, catalog::NEGATIVE_KINDS, Bnafar::Catalog::EXTERNAL_EXIT_TYPES ])
    expect { AddStockExternalExits.new.down }.to raise_error(ActiveRecord::IrreversibleMigration)
  end

  describe "stock_external_exits" do
    it "saída sem destino ou com destino malformado → CHECK" do
      refused(/destination_code/) { exit!(destination_code: nil) }
      refused(/ck_stock_external_exits_destination/) { exit!(destination_kind: "cnes", destination_code: "12ABC34501DE35") }
      refused(/ck_stock_external_exits_destination/) { exit!(destination_kind: "cnpj", destination_code: "1234567") }
      refused(/ck_stock_external_exits_destination/) { exit!(destination_kind: "cnes", destination_code: "123456") }
      refused(/ck_stock_external_exits_destination/) { exit!(destination_kind: "cpf", destination_code: "1234567") }
      refused(/ck_stock_external_exits_type/) { exit!(exit_type: "S-T") }
    end

    it "CNPJ alfanumérico e CNES de 7 dígitos passam; a versão nasce em 1" do
      expect(exit!.reload).to have_attributes(destination_code: "12ABC34501DE35", version: 1)
      expect(exit!(destination_kind: "cnes", destination_code: "2384299", exit_type: "S-TR")).to be_persisted
    end

    it "UPDATE do destino com version + 1 passa; do local ou sem a versão → trigger" do
      row = exit!
      row.update_columns(destination_code: "99ABC34501DE99", exit_type: "S-E", version: 2)
      expect(row.reload).to have_attributes(destination_code: "99ABC34501DE99", exit_type: "S-E", version: 2)
      refused(/stock_external_exits/) { row.update_columns(stock_location_id: unit_location!.id, version: 3) }
      refused(/stock_external_exits/) { row.update_columns(destination_kind: "cnes", destination_code: "2384299") }
      refused(/stock_external_exits/) { row.update_columns(destination_code: "12ABC34501DE35", version: 9) }
      refused(/stock_external_exits/) { row.update_columns(recorded_at: 1.day.ago, version: 3) }
      refused(/stock_external_exits/) { row.delete }
    end

    it "re-cifra da razão passa sob a marca; fora dela, mudar só a razão sem a versão cai" do
      row = exit!
      CityEncryption.allowing_reencryption { row.encrypt }
      refused(/stock_external_exits/) { row.update_columns(reason: "outro texto qualquer", version: 1) }
    end

    it "itens: quantidade > 0, único por (saída, lote), só acréscimo" do
      external = exit!
      refused(/ck_stock_external_exit_items_quantity/) { item!(external, quantity: 0) }
      row = item!(external)
      expect { item!(external) }.to raise_error(ActiveRecord::RecordNotUnique, /idx_stock_external_exit_items_once/)
      refused(/stock_external_exit_items/) { row.update_columns(quantity: 6) }
      refused(/stock_external_exit_items/) { row.delete }
    end

    it "TRUNCATE recusado nas duas tabelas" do
      refused(/append-only: TRUNCATE refused/) { ApplicationRecord.connection.execute("TRUNCATE stock_external_exits CASCADE") }
      refused(/append-only: TRUNCATE refused/) { ApplicationRecord.connection.execute("TRUNCATE stock_external_exit_items CASCADE") }
    end
  end

  describe "stock_movements" do
    it "external_exit com a saída passa; positivo → CHECK sign; sem documento → CHECK document" do
      external = exit!
      expect(movement!(stock_external_exit: external)).to be_persisted
      refused(/ck_stock_movements_sign/) { movement!(stock_external_exit: external, quantity: 5) }
      refused(/ck_stock_movements_document/) { movement! }
      refused(/ck_stock_movements_document/) { movement!(stock_external_exit: external, kind: "loss", reason: "Frascos quebrados no transporte") }
    end

    it "opening_reversal documentado pela entrada de abertura passa; positivo ou sem entrada cai" do
      entry = StockEntry.create!(stock_location: central, kind: "opening", recorded_by_user: keeper)
      expect(movement!(kind: "opening_reversal", stock_entry: entry)).to be_persisted
      refused(/ck_stock_movements_sign/) { movement!(kind: "opening_reversal", stock_entry: entry, quantity: 5) }
      refused(/ck_stock_movements_document/) { movement!(kind: "opening_reversal") }
    end
  end

  describe "stock_openings" do
    def opening!(item: losartana)
      entry = StockEntry.create!(stock_location: central, kind: "opening", recorded_by_user: keeper)
      StockOpening.create!(stock_location: central, catalog_item_id: item.id, stock_entry: entry)
    end

    it "abertura revertida libera o índice; uma ativa por (local, item) continua" do
      first = opening!
      expect { opening! }.to raise_error(ActiveRecord::RecordNotUnique, /idx_stock_openings_once/)
      first.update_columns(reverted_at: Time.current)
      expect(opening!).to be_persisted
      expect(StockOpening.active.count).to eq(1)
    end

    it "reverted_at duas vezes → trigger; trocar outra coluna → trigger; DELETE → trigger" do
      row = opening!
      refused(/stock_openings/) { row.update_columns(created_at: 1.day.ago) }
      row.update_columns(reverted_at: Time.current)
      refused(/stock_openings/) { row.update_columns(reverted_at: Time.current + 1) }
      refused(/stock_openings/) { row.update_columns(reverted_at: nil) }
      refused(/stock_openings/) { row.delete }
    end
  end
end
