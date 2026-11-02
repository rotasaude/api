require "rails_helper"

# Módulo 29 (ADR 0047): o banco da sala de vacina. A dose é imutável (só o
# cancelamento, uma vez); leitura de temperatura e conferência só crescem; o
# payload da fila RNDS vai a nulo no aceite; o lote de imunobiológico não tem
# CATMAT e o razão do 27a ganha os locais da vacina.
RSpec.describe "Esquema do módulo 29", type: :model do
  let!(:city) { vaccination_city! }
  let(:room) { vaccine_room! }

  # Escrita crua que o banco recusa: sem savepoint, a recusa aborta a transação
  # do exemplo e o resto falha com InFailedSqlTransaction.
  def refused(pattern = nil, &block)
    expect { ApplicationRecord.transaction(requires_new: true, &block) }.to raise_error(ActiveRecord::StatementInvalid, pattern)
  end

  it "lote de imunobiológico sem CATMAT; medicamento sem código de imunobiológico" do
    by = room.updated_by_user
    expect { StockLot.create!(item_kind: "immunobiological", immunobiological_code: "42", lot_number: "P1", expires_on: Date.tomorrow, dispensing_unit: "dose", created_by_user: by) }.not_to raise_error
    expect { StockLot.create!(item_kind: "immunobiological", immunobiological_code: "42", catmat_code: 1, catalog_item_id: SecureRandom.uuid, lot_number: "P2", expires_on: Date.tomorrow, dispensing_unit: "dose", created_by_user: by) }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_stock_lots_item/)
    expect { StockLot.create!(item_kind: "medication", immunobiological_code: "42", catmat_code: 1, catalog_item_id: SecureRandom.uuid, lot_number: "P3", expires_on: Date.tomorrow, dispensing_unit: "comprimido", created_by_user: by) }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_stock_lots_item/)
  end

  it "um vaccine_room por unidade, e a unidade aceita unit e vaccine_room juntos" do
    expect(StockLocation.where(health_unit_id: room.health_unit_id).pluck(:kind)).to eq([ "vaccine_room" ])
    expect { StockLocation.create!(kind: "vaccine_room", name: "Outra", health_unit: room.health_unit, updated_by_user: room.updated_by_user) }
      .to raise_error(ActiveRecord::RecordNotUnique)
    expect { StockLocation.create!(kind: "unit", name: "Farmácia da sala", health_unit: room.health_unit, updated_by_user: room.updated_by_user) }
      .not_to raise_error
    cold_chain_central!
    expect { StockLocation.create!(kind: "cold_chain_central", name: "Outra rede", updated_by_user: room.updated_by_user) }
      .to raise_error(ActiveRecord::RecordNotUnique, /idx_stock_locations_one_cold_chain_central/)
  end

  it "dose imutável: UPDATE fora do cancelamento e DELETE recusados; cancelar é uma vez" do
    dose = create_immunization!(room)
    refused(/immunizations/) { dose.update_column(:dose_code, "2") }
    dose.update!(cancelled_at: Time.current, cancelled_by_user: dose.vaccinator_user, cancel_reason: "Lote digitado errado na sala")
    expect { dose.update!(cancelled_at: 1.minute.from_now) }.to raise_error(ActiveRecord::StatementInvalid, /cancelled once/)
    refused { dose.delete }
  end

  it "dose aplicada exige sala, lote e via; transcrição não tem lote do estoque" do
    expect { create_immunization!(room, route: nil) }.to raise_error(ActiveRecord::StatementInvalid, /ck_immunizations_transcription/)
    expect { create_immunization!(room, transcription: true) }.to raise_error(ActiveRecord::StatementInvalid, /ck_immunizations_transcription/)
    transcribed = create_immunization!(room, transcription: true, stock_lot: nil, vaccine_room: nil, care_group: nil, route: nil, site: nil,
                                             lot_number_text: "TX-9", place_text: "Maternidade")
    expect(transcribed.reload.lot_number_text).to eq("TX-9")
  end

  it "leitura de temperatura e conferência são só acréscimo" do
    reading = ColdChainReading.create!(cold_chain_equipment: cold_chain_equipment!(room), read_at: Time.current, current_c: 5, min_c: 3, max_c: 7, recorded_by_user: room.updated_by_user)
    refused { reading.update_column(:current_c, 4) }
    check = VaccinationRecordCheck.create!(patient: vaccine_patient!(birth_date: Date.current - 400), vaccine_room: room, checked_by_user: room.updated_by_user,
                                           mode: "confirmed_complete", checked_at: Time.current)
    refused(/append-only/) { check.update_column(:mode, "transcribed") }
    expect { VaccinationRecordCheck.create!(patient: check.patient, mode: "confirmed_complete", checked_at: Time.current) }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_vaccination_record_checks_author/)
  end

  it "payload da fila vai a nulo no aceite, e só no aceite" do
    entry = RndsOutboxEntry.create!(immunization: create_immunization!(room), kind: "application", status: "pending", payload: "{}", next_attempt_at: Time.current, deadline_at: 1.day.from_now)
    expect { entry.update!(status: "accepted", accepted_at: Time.current) }.to raise_error(ActiveRecord::StatementInvalid, /payload/)
    refused(/DELETE refused/) { entry.delete }
  end

  it "frasco fecha uma vez; excursão decide uma vez; vínculo da sala revoga uma vez" do
    vial = VialOpening.create!(vaccine_room: room, stock_lot: vaccine_lot!(room, code: "22", doses: 20), opened_by_user: room.updated_by_user,
                               opened_at: Time.current, expires_at: 6.hours.from_now, doses_per_vial: 10)
    refused(/vial_openings/) { vial.update_column(:doses_per_vial, 5) }
    vial.update!(closed_at: Time.current, closed_by_user: room.updated_by_user, close_reason: "Frasco caiu durante o preparo", technical_loss_doses: 10)
    refused(/closed once/) { vial.update_column(:technical_loss_doses, 9) }

    reading = ColdChainReading.create!(cold_chain_equipment: cold_chain_equipment!(room), read_at: Time.current, current_c: 9.5, min_c: 3, max_c: 9.5,
                                       recorded_by_user: room.updated_by_user)
    excursion = ColdChainExcursion.create!(cold_chain_reading: reading, stock_location: room.stock_location)
    excursion.update!(decided_at: Time.current, decided_by_user: room.updated_by_user)
    refused(/decided once/) { excursion.update_column(:decided_at, 1.minute.from_now) }

    link = VaccineRoomStaff.find_by!(user: room_member!(room), vaccine_room: room)
    refused(/only revoked_at and revoked_by_user_id change/) { link.update_column(:role, "room_lead") }
    link.update!(revoked_at: Time.current, revoked_by_user: room.updated_by_user)
    refused(/revoked once/) { link.update_column(:revoked_at, 1.minute.from_now) }
    refused(/DELETE refused/) { room.delete }
  end

  # Task 14, fix round 1 (I2): o bloqueio é registro da conduta.
  it "bloqueio de lote: identidade imutável, conduta refeita enquanto aberto, liberado congela, re-cifra só do motivo" do
    lot = vaccine_lot!(room, code: "22", doses: 20)
    block = lot_block!(room.stock_location, lot)
    user = room.updated_by_user
    refused(/only the decision columns/) { block.update_column(:stock_lot_id, vaccine_lot!(room).id) }
    refused(/only the decision columns/) { block.update_column(:stock_location_id, vaccine_room!.stock_location_id) }
    refused(/only the decision columns/) { block.update_column(:cold_chain_excursion_id, lot_block!(room.stock_location, lot).cold_chain_excursion_id) }
    block.update!(decided_by_user: user, decision_reason: "Exposição longa acima de 8 graus")
    block.update!(decided_by_user: user, decision_reason: "Termômetro conferido, sem perda")
    block.update!(released_at: Time.current, decision: "use")
    refused(/a released block never changes/) { block.update_columns(released_at: nil, decision: nil) }
    refused(/a released block never changes/) { block.update_column(:decision, "discard") }
    refused(/a released block never changes/) { block.update_column(:decided_by_user_id, room_member!(room).id) }
    expect { CityEncryption.allowing_reencryption { block.encrypt } }.not_to raise_error
    expect(block.reload.decision_reason).to eq("Termômetro conferido, sem perda")
    refused(/stock_lot_blocks/) { CityEncryption.allowing_reencryption { block.update_columns(decision_reason: "x", decision: "discard") } }
    refused(/DELETE refused/) { block.delete }
  end

  it "a re-cifra regrava só as colunas cifradas da dose e do frasco" do
    dose = create_immunization!(room, override_reason: "Viagem da família para fora do país")
    dose.update!(cancelled_at: Time.current, cancelled_by_user: dose.vaccinator_user, cancel_reason: "Paciente errado na busca")
    expect { CityEncryption.allowing_reencryption { dose.encrypt } }.not_to raise_error
    expect(dose.reload).to have_attributes(override_reason: "Viagem da família para fora do país", cancel_reason: "Paciente errado na busca")
    refused(/immunizations/) { CityEncryption.allowing_reencryption { dose.update_columns(cancel_reason: "x", dose_code: "3") } }
    expect(CityEncryption::CITY_KEYED_TARGETS).to include([ Immunization, :override_reason ], [ RndsOutboxEntry, :payload ], [ VialOpening, :close_reason ])
  end

  # O id (uuid em hex) pode conter "42" por acaso: tira-se o id antes de
  # procurar o código da vacina.
  it "nada pessoal em inspect/as_json" do
    dose = create_immunization!(room)
    expect([ dose.inspect, dose.as_json.to_s ].join.gsub(dose.id, "")).not_to include("42")
    expect(dose.as_json).to eq("id" => dose.id)
  end
end
