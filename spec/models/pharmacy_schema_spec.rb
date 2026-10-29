require "rails_helper"
require Rails.root.join("db/city_migrate/20261029900001_add_pharmacy_stock.rb").to_s

# Módulo 27a (ADR 0045): o banco da farmácia. O saldo é a soma dos movimentos
# (só acréscimo, nunca negativo); os CHECKs e os triggers (db/city_triggers.sql)
# seguram o que o código não pode quebrar.
RSpec.describe "Esquema da farmácia (ADR 0045)" do
  before { pharmacy_city! }
  let(:keeper) { staff_with("almox-#{SecureRandom.hex(2)}@cidade.gov.br", "stock_keeper") }
  let(:central) { central_location! }
  let(:lot) do
    StockLot.create!(catalog_item_id: losartana.id, catmat_code: 268_856, lot_number: "LS01", expires_on: Date.current + 200,
                     dispensing_unit: "comprimido", created_by_user: keeper)
  end
  let(:entry) { StockEntry.create!(stock_location: central, kind: "invoice", document_number: "NF-1", supplier: "Distribuidora", recorded_by_user: keeper) }

  def movement(**over)
    StockMovement.create!({ stock_location: central, stock_lot: lot, catalog_item_id: lot.catalog_item_id, kind: "receipt", quantity: 10,
                            stock_entry: entry, recorded_by_user: keeper, recorded_at: Time.current }.merge(over))
  end

  # Perda aplicada crua (sem o comando da Task 7), documento do movimento loss.
  def loss_adjustment!(location, lot, by)
    StockAdjustment.create!(stock_location: location, stock_lot: lot, kind: "loss", status: "applied", quantity: -11, balance_at_request: 10,
                            reason: "Frascos quebrados no transporte", requested_by_user: by)
  end

  # Escrita crua (delete, update_columns, SQL) que o banco recusa: sem savepoint,
  # a recusa aborta a transação do exemplo e o resto falha com
  # InFailedSqlTransaction (o create! já roda no savepoint dele).
  def refused(pattern = nil, &block)
    expect { ApplicationRecord.transaction(requires_new: true, &block) }.to raise_error(ActiveRecord::StatementInvalid, pattern)
  end

  it "movimento nunca muda nem some; sinal pelo tipo; documento obrigatório" do
    row = movement
    refused(/append-only: UPDATE refused/) { row.update_columns(quantity: 20) }
    refused(/append-only: DELETE refused/) { row.delete }
    expect { movement(quantity: -1) }.to raise_error(ActiveRecord::StatementInvalid, /ck_stock_movements_sign/)
    expect { movement(stock_entry: nil) }.to raise_error(ActiveRecord::StatementInvalid, /ck_stock_movements_document/)
    expect { movement(quantity: BigDecimal("100000")) }.to raise_error(ActiveRecord::StatementInvalid, /ck_stock_movements_sign/)
    refused(/append-only: TRUNCATE refused/) { ApplicationRecord.connection.execute("TRUNCATE stock_movements") }
  end

  it "o trigger recusa saldo negativo por local e lote" do
    movement
    expect do
      movement(kind: "loss", quantity: -11, stock_entry: nil, stock_adjustment: loss_adjustment!(central, lot, keeper),
               reason: "Frascos quebrados no transporte")
    end.to raise_error(ActiveRecord::StatementInvalid, /negative balance refused/)
    expect(StockMovement.where(stock_location: central, stock_lot: lot).sum(:quantity)).to eq(10)
  end

  it "um central só; unidade com health_unit; abertura uma vez por local e item; lote único por item" do
    central
    expect { StockLocation.create!(kind: "central", name: "Outro central", updated_by_user: keeper) }
      .to raise_error(ActiveRecord::RecordNotUnique, /idx_stock_locations_one_central/)
    expect { StockLocation.create!(kind: "unit", name: "Sem unidade", updated_by_user: keeper) }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_stock_locations_unit/)
    StockOpening.create!(stock_location: central, catalog_item_id: losartana.id, stock_entry: entry)
    expect { StockOpening.create!(stock_location: central, catalog_item_id: losartana.id, stock_entry: entry) }
      .to raise_error(ActiveRecord::RecordNotUnique, /idx_stock_openings_once/)
    lot
    expect { StockLot.create!(lot.attributes.except("id", "created_at")) }.to raise_error(ActiveRecord::RecordNotUnique, /idx_stock_lots_number/)
  end

  it "ajuste decide uma vez e nunca pelo autor; dispensação e receita externa imutáveis" do
    adjustment = StockAdjustment.create!(stock_location: central, stock_lot: lot, kind: "adjustment", status: "pending", quantity: -5,
                                         counted_quantity: 5, balance_at_request: 10, reason: "Contagem do inventário de outubro",
                                         requested_by_user: keeper)
    expect { adjustment.update!(status: "approved", decided_by_user: keeper, decided_at: Time.current) }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_stock_adjustments_decider/)
    other = staff_with("almox2-#{SecureRandom.hex(2)}@cidade.gov.br", "stock_keeper")
    adjustment.update!(status: "rejected", decided_by_user: other, decided_at: Time.current, decision_reason: "Recontar a prateleira B")
    refused(/decided once/) { adjustment.update_columns(status: "approved") }
    refused(/DELETE refused/) { adjustment.delete }

    patient = registry_patient!
    unit = unit_location!
    external = ExternalPrescription.create!(patient: patient, stock_location: unit, prescriber_name: "Dra. Beltrana", council: "CRM",
                                            council_state: "PR", council_number: "12345", issued_on: Date.current,
                                            notification_number: "PR-123456", recorded_by_user: keeper)
    item = ExternalPrescriptionItem.create!(external_prescription: external, position: 1, catalog_item_id: losartana.id, catmat_code: 268_856,
                                            quantity: BigDecimal("99999.99"), quantity_unit: "comprimido",
                                            dosage_instructions: "1 comprimido ao dia")
    refused(/append-only: UPDATE refused/) { external.update_columns(issued_on: Date.current - 1) }
    refused(/append-only: UPDATE refused/) { item.update_columns(quantity: 2) }
    dispensation = Dispensation.create!(stock_location: unit, patient: patient, external_prescription: external, dispensed_by_user: keeper,
                                        dispensed_by_role: "pharmacist", dispensed_at: Time.current)
    refused(/append-only: UPDATE refused/) { dispensation.update_columns(retained: true) }
    expect do
      Dispensation.create!(stock_location: unit, patient: patient, dispensed_by_user: keeper, dispensed_by_role: "pharmacist",
                           dispensed_at: Time.current)
    end.to raise_error(ActiveRecord::StatementInvalid, /ck_dispensations_prescription/)
    expect do
      ExternalPrescriptionItem.create!(external_prescription: external, position: 2, catalog_item_id: losartana.id, catmat_code: 268_856,
                                       quantity: BigDecimal("100000"), quantity_unit: "comprimido", dosage_instructions: "1 ao dia")
    end.to raise_error(ActiveRecord::StatementInvalid, /ck_external_prescription_items_quantity/)
  end

  it "transferência e vínculo mudam uma vez; local, mínimo e parâmetros nunca somem" do
    unit = unit_location!
    transfer = StockTransfer.create!(from_location: central, to_location: unit, status: "sent", sent_by_user: keeper, sent_at: Time.current)
    item = StockTransferItem.create!(stock_transfer: transfer, stock_lot: lot, quantity_sent: 10)
    refused(/only quantity_received and difference_reason change/) { item.update_columns(quantity_sent: 9) }
    item.update!(quantity_received: 8, difference_reason: "Duas caixas avariadas")
    refused(/received once/) { item.update_columns(quantity_received: 7) }
    refused(/only status, received_by_user_id and received_at change/) { transfer.update_columns(sent_at: Time.current - 60) }
    transfer.update!(status: "received_with_difference", received_by_user: keeper, received_at: Time.current)
    refused(/received once/) { transfer.update_columns(status: "received") }
    refused(/DELETE refused/) { transfer.delete }

    link = StockLocationStaff.create!(stock_location: unit, user: keeper, role: "stock_keeper", granted_by_user: pharmacy_admin!, granted_at: Time.current)
    refused(/only revoked_at and revoked_by_user_id change/) { link.update_columns(role: "pharmacist") }
    link.update!(revoked_at: Time.current, revoked_by_user: pharmacy_admin!)
    refused(/revoked once/) { link.update_columns(revoked_at: Time.current + 60) }

    minimum = StockMinimum.create!(stock_location: unit, catalog_item_id: losartana.id, minimum: BigDecimal("99999.99"), updated_by_user: keeper)
    refused(/DELETE refused/) { minimum.delete }
    refused(/DELETE refused/) { unit.delete }
    refused(/DELETE refused/) { PharmacySetting.current.delete }
  end

  it "papéis novos aceitos; farmacêutico e auxiliar privilegiados, almoxarife não; nada pessoal no inspect" do
    %w[pharmacist pharmacy_assistant stock_keeper].each do |role|
      expect { staff_with("#{role}-#{SecureRandom.hex(2)}@c.gov.br", role) }.not_to raise_error
    end
    expect(Membership::PRIVILEGED_ROLES).to include("pharmacist", "pharmacy_assistant")
    expect(Membership::PRIVILEGED_ROLES).not_to include("stock_keeper")
    expect(PharmacySetting.current.attributes.slice(*Pharmacy::Catalog::DEFAULT_SETTINGS.keys)).to eq(Pharmacy::Catalog::DEFAULT_SETTINGS)
    external = ExternalPrescription.new(prescriber_name: "Dr. Fulano", notification_number: "PR-123456")
    expect(external.inspect).not_to include("PR-123456")
    expect(external.as_json.keys).to eq([ "id" ])
    movement_row = StockMovement.new(kind: "loss", reason: "Frascos quebrados no transporte")
    expect([ movement_row.inspect, movement_row.to_s ]).to all(satisfy { |text| !text.include?("Frascos") })
    expect(StockAdjustment.new(reason: "Contagem do inventário", decision_reason: "Recontar").as_json.keys).to eq([ "id" ])
  end

  it "a re-cifra regrava só o texto cifrado nas 7 colunas; outra coluna continua recusada" do
    unit = unit_location!
    patient = registry_patient!
    entry
    adjustment = StockAdjustment.create!(stock_location: central, stock_lot: lot, kind: "adjustment", status: "pending", quantity: -5,
                                         counted_quantity: 5, balance_at_request: 10, reason: "Contagem do inventário de outubro",
                                         requested_by_user: keeper)
    adjustment.update!(status: "rejected", decided_by_user: pharmacy_admin!, decided_at: Time.current, decision_reason: "Recontar a prateleira")
    transfer = StockTransfer.create!(from_location: central, to_location: unit, status: "sent", sent_by_user: keeper, sent_at: Time.current)
    transfer_item = StockTransferItem.create!(stock_transfer: transfer, stock_lot: lot, quantity_sent: 10)
    transfer_item.update!(quantity_received: 9, difference_reason: "Uma caixa avariada")
    external = ExternalPrescription.create!(patient: patient, stock_location: unit, prescriber_name: "Dra. Beltrana", council: "CRO",
                                            council_state: "SP", council_number: "999", issued_on: Date.current,
                                            notification_number: "SP-1", recorded_by_user: keeper)
    external_item = ExternalPrescriptionItem.create!(external_prescription: external, position: 1, catalog_item_id: losartana.id,
                                                     catmat_code: 268_856, quantity: 30, quantity_unit: "comprimido",
                                                     dosage_instructions: "1 comprimido ao dia")
    dispensation = Dispensation.create!(stock_location: unit, patient: patient, external_prescription: external, dispensed_by_user: keeper,
                                        dispensed_by_role: "pharmacist", dispensed_at: Time.current, retained: true, notification_number: "SP-1")
    movement
    loss = movement(kind: "loss", quantity: -1, stock_entry: nil, reason: "Frasco quebrado na prateleira",
                    stock_adjustment: StockAdjustment.create!(stock_location: central, stock_lot: lot, kind: "loss", status: "applied", quantity: -1,
                                                              balance_at_request: 10, reason: "Frasco quebrado", requested_by_user: keeper))
    rows = [ adjustment, transfer_item, external, external_item, dispensation, loss ]

    expect { CityEncryption.allowing_reencryption { rows.each(&:encrypt) } }.not_to raise_error
    expect(rows.map(&:reload).map { |r| r.class.encrypted_attributes.map { |a| r.public_send(a) } })
      .to eq([ [ "Contagem do inventário de outubro", "Recontar a prateleira" ], [ "Uma caixa avariada" ], [ "SP-1" ],
               [ "1 comprimido ao dia" ], [ "SP-1" ], [ "Frasco quebrado na prateleira" ] ])
    refused(/decided once|only status/) { CityEncryption.allowing_reencryption { adjustment.update_columns(reason: "outro", quantity: -4) } }
    refused(/only quantity_received/) { CityEncryption.allowing_reencryption { transfer_item.update_columns(difference_reason: "x", quantity_sent: 8) } }
    expect(CityEncryption::CITY_KEYED_TARGETS).to include(
      [ StockMovement, :reason ], [ StockTransferItem, :difference_reason ], [ StockAdjustment, :reason ], [ StockAdjustment, :decision_reason ],
      [ ExternalPrescription, :notification_number ], [ ExternalPrescriptionItem, :dosage_instructions ], [ Dispensation, :notification_number ]
    )
  end

  # Revisão da Task 2 (rodada 1): decisor junto com a decisão; o teto de
  # 99999.99 vale para o delta, não para contagem e saldo; perda e vencimento
  # sempre negativos.
  it "ajuste: decisão sem decisor recusada; contagem e saldo sem teto, delta com teto; perda e vencimento negativos" do
    base = { stock_location: central, stock_lot: lot, reason: "Contagem do inventário de outubro", requested_by_user: keeper }
    pending = StockAdjustment.create!(base.merge(kind: "adjustment", status: "pending", quantity: -5, counted_quantity: 5, balance_at_request: 10))
    refused(/ck_stock_adjustments_decided_by/) { pending.update_columns(status: "approved", decided_at: Time.current) }

    big = base.merge(kind: "adjustment", status: "applied", counted_quantity: BigDecimal("150000.50"), balance_at_request: BigDecimal("200000"))
    expect { StockAdjustment.create!(big.merge(quantity: BigDecimal("-49999.50"))) }.not_to raise_error
    expect { StockAdjustment.create!(big.merge(quantity: BigDecimal("-100000"))) }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_stock_adjustments_quantity/)
    %w[loss expiry].each do |kind|
      expect { StockAdjustment.create!(base.merge(kind: kind, status: "applied", quantity: 1, balance_at_request: 10)) }
        .to raise_error(ActiveRecord::StatementInvalid, /ck_stock_adjustments_sign/)
    end
    expect { StockAdjustment.create!(base.merge(kind: "adjustment", status: "applied", quantity: 2, counted_quantity: 12, balance_at_request: 10)) }
      .not_to raise_error
  end

  it "o item do catálogo do movimento e do item dispensado é o do lote" do
    expect { movement(catalog_item_id: amoxicilina.id) }.to raise_error(ActiveRecord::StatementInvalid, /catalog_item_id differs from the lot/)
    unit = unit_location!
    external = ExternalPrescription.create!(patient: registry_patient!, stock_location: unit, prescriber_name: "Dra. Beltrana", council: "CRM",
                                            council_state: "PR", council_number: "12345", issued_on: Date.current, recorded_by_user: keeper)
    item = ExternalPrescriptionItem.create!(external_prescription: external, position: 1, catalog_item_id: losartana.id, catmat_code: 268_856,
                                            quantity: 30, quantity_unit: "comprimido", dosage_instructions: "1 comprimido ao dia")
    dispensation = Dispensation.create!(stock_location: unit, patient: external.patient, external_prescription: external, dispensed_by_user: keeper,
                                        dispensed_by_role: "pharmacist", dispensed_at: Time.current)
    line = { dispensation: dispensation, external_prescription_item: item, stock_lot: lot, quantity: 1 }
    expect { DispensationItem.create!(line.merge(catalog_item_id: amoxicilina.id)) }
      .to raise_error(ActiveRecord::StatementInvalid, /catalog_item_id differs from the lot/)
    expect { DispensationItem.create!(line.merge(catalog_item_id: losartana.id)) }.not_to raise_error
  end

  it "stocked_lot! recusa reaproveitar o lote com outra validade" do
    stocked_lot!(central, item: losartana, lot_number: "LS03", expires_on: Time.zone.today + 180)
    expect { stocked_lot!(central, item: losartana, lot_number: "LS03", expires_on: Time.zone.today + 90) }
      .to raise_error(ArgumentError, /expires_on/)
    expect { stocked_lot!(central, item: losartana, lot_number: "LS03", expires_on: Time.zone.today + 180) }.not_to raise_error
  end

  # A migração espelha Pharmacy::Catalog (não lê código da aplicação): as
  # listas do banco e as do código nascem iguais.
  it "a migração espelha as listas de Pharmacy::Catalog" do
    catalog = Pharmacy::Catalog
    expect([ AddPharmacyStock::LOCATION_KINDS, AddPharmacyStock::STAFF_ROLES, AddPharmacyStock::DISPENSER_ROLES, AddPharmacyStock::MOVEMENT_KINDS,
             AddPharmacyStock::POSITIVE_KINDS, AddPharmacyStock::NEGATIVE_KINDS, AddPharmacyStock::ENTRY_KINDS, AddPharmacyStock::TRANSFER_STATUSES,
             AddPharmacyStock::ADJUSTMENT_KINDS, AddPharmacyStock::ADJUSTMENT_STATUSES, AddPharmacyStock::COUNCILS, AddPharmacyStock::DEFAULT_SETTINGS,
             AddPharmacyStock::SETTING_RANGES, AddPharmacyStock::PACKAGES ])
      .to eq([ catalog::LOCATION_KINDS, catalog::ROLES, catalog::DISPENSER_ROLES, catalog::MOVEMENT_KINDS, catalog::POSITIVE_KINDS,
               catalog::NEGATIVE_KINDS, catalog::ENTRY_KINDS, catalog::TRANSFER_STATUSES, catalog::ADJUSTMENT_KINDS, catalog::ADJUSTMENT_STATUSES,
               catalog::COUNCILS, catalog::DEFAULT_SETTINGS, catalog::SETTING_RANGES, catalog::PACKAGE_RANGE ])
    expect(Pharmacy::Quantity.parse(AddPharmacyStock::MAX_QUANTITY)).to eq(BigDecimal("99999.99"))
  end

  it "stocked_lot! abre o item no local e depois entra por nota; balance_of soma o local" do
    stocked = stocked_lot!(central, item: losartana, quantity: "30", lot_number: "LS02", by: keeper)
    stocked_lot!(central, item: losartana, quantity: "12.50", lot_number: "LS02", by: keeper)
    expect(StockEntry.where(stock_location: central).pluck(:kind)).to contain_exactly("opening", "invoice")
    expect(balance_of(central, stocked)).to eq(BigDecimal("42.50"))
    expect(balance_of(unit_location!, stocked)).to eq(0)
  end
end
