# Situação da cadeia de frio de um local de vacina (ADR 0047; contrato §8;
# §15 V14 = D9 do dashboard). Só contagens e lotes, nenhum dado de paciente,
# sem trilha:
#
#   { equipments: [ { <equipamento>, last_reading|null, readings_today } ],
#     open_excursions: [ { id, equipment_id, reading, lots: [ { lot_id, number,
#       immunobiological: { code, name|null }, balance, pending_adjustment_id } ],
#       opened_at } ] }
#
# `equipments`: os ativos do local (nome, id). `readings_today`: leituras com
# `read_at` no dia da cidade (a meta é READINGS_PER_DAY). `lots`: os
# bloqueios ainda abertos da excursão, com o saldo do lote no local e, quando
# o descarte espera aprovação, o id do ajuste pendente (acréscimo ao D9: a
# tela sabe que aquele lote já tem conduta). Temperaturas com uma casa.
module Vaccination
  module ColdChainStatus
    module_function

    def call(location:, now: Time.current)
      day = now.in_time_zone.all_day
      equipments = ColdChainEquipment.active_equipments.where(stock_location_id: location.id).order(:name, :id).to_a
      { equipments: equipments.map { |equipment| equipment_status(equipment, day) }, open_excursions: open_excursions(location) }
    end

    def equipment_status(equipment, day)
      last = equipment.readings.includes(:excursion, recorded_by_user: :professional).order(read_at: :desc, id: :desc).first
      equipment_json(equipment).merge(last_reading: last && reading_json(last), readings_today: equipment.readings.where(read_at: day).count)
    end

    def open_excursions(location)
      excursions = ColdChainExcursion.open_excursions.where(stock_location_id: location.id)
                                     .includes(cold_chain_reading: [ :excursion, { recorded_by_user: :professional } ])
                                     .order(:created_at, :id).to_a
      blocks = StockLotBlock.open_blocks.where(cold_chain_excursion_id: excursions.map(&:id)).includes(:stock_lot, :stock_adjustment)
                            .order(:stock_lot_id).group_by(&:cold_chain_excursion_id)
      balances = Pharmacy::Ledger.balances(location_id: location.id, lot_ids: blocks.values.flatten.map(&:stock_lot_id))
      excursions.map do |excursion|
        reading = excursion.cold_chain_reading
        { id: excursion.id, equipment_id: reading.cold_chain_equipment_id, reading: reading_json(reading),
          lots: blocks.fetch(excursion.id, []).map { |block| lot_line(block, balances) }, opened_at: excursion.created_at.iso8601 }
      end
    end

    def lot_line(block, balances)
      lot = block.stock_lot
      adjustment = block.stock_adjustment
      { lot_id: lot.id, number: lot.lot_number,
        immunobiological: { code: lot.immunobiological_code, name: Immunobiologicals.find(lot.immunobiological_code)&.name },
        balance: Pharmacy::Quantity.dump(balances.fetch(lot.id, 0)), pending_adjustment_id: (adjustment.id if adjustment&.status == "pending") }
    end

    # { id, location_id, name, kind, min_c, max_c, active }
    def equipment_json(equipment)
      { id: equipment.id, location_id: equipment.stock_location_id, name: equipment.name, kind: equipment.kind,
        min_c: Temperature.dump(equipment.min_c), max_c: Temperature.dump(equipment.max_c), active: equipment.active }
    end

    # { id, read_at, current_c, min_c, max_c, out_of_range, by: { name } }. Fora
    # da faixa = a leitura abriu excursão (vale a faixa do dia da leitura).
    def reading_json(reading)
      { id: reading.id, read_at: reading.read_at.iso8601, current_c: Temperature.dump(reading.current_c),
        min_c: Temperature.dump(reading.min_c), max_c: Temperature.dump(reading.max_c), out_of_range: reading.excursion.present?,
        by: { name: reading.recorded_by_user.professional&.professional_name } }
    end
  end
end
