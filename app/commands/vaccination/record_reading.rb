# Leitura de temperatura do equipamento (ADR 0047; contrato §8; §15 V14 = D9;
# Review Focus 4). Qualquer da equipe do local registra (o controlador
# confere). Corpo `{ read_at, current_c, min_c, max_c }`: hora ISO 8601 não
# futura (até 5 min de folga do relógio do aparelho → `read_at_in_future`),
# temperaturas com uma casa decimal, mínima ≤ atual ≤ máxima (`invalid_range`,
# path `current_c`). Equipamento inativo → `equipment_inactive` (409).
#
# Fora da faixa quando a atual, a mínima OU a máxima fica abaixo do `min_c` ou
# acima do `max_c` do equipamento: nasce a excursão e um bloqueio por lote do
# local — os lotes com saldo > 0 e os dos frascos ainda abertos na sala (a
# dose do frasco aberto também para). Lote vencido não entra (já não dá dose
# nem abre frasco). Lote já bloqueado por outra excursão ganha outro bloqueio:
# cada excursão tem a sua conduta. O insert do bloqueio pede FOR KEY SHARE no
# lote e espera a dose em curso (que trava o lote FOR UPDATE).
#
# Evento `vaccination.cold_chain_excursion` só com ids.
module Vaccination
  module RecordReading
    CLOCK_SLACK = 5.minutes
    TEMPERATURES = %w[current_c min_c max_c].freeze

    module_function

    # -> Result.ok(reading:, excursion: | nil, blocked_lots: Integer) |
    # fail(:equipment_inactive) | fail(<erro>, details: { path:, problems: })
    def call(equipment:, attrs:, by:, now: Time.current)
      return Result.fail(:equipment_inactive) unless equipment.active

      attrs = attrs.to_h.stringify_keys
      problems = []
      read_at = parse_time(attrs["read_at"])
      if read_at.nil?
        problems << problem("read_at", :invalid_request)
      elsif read_at > now + CLOCK_SLACK
        problems << problem("read_at", :read_at_in_future)
      end
      values = TEMPERATURES.to_h { |key| [ key, Temperature.parse(attrs[key]) ] }
      values.each { |key, value| problems << problem(key, :invalid_request) unless value }
      current, min, max = values.values_at(*TEMPERATURES)
      problems << problem("current_c", :invalid_range) if current && min && max && !(min <= current && current <= max)
      return failure(problems) if problems.any?

      result = nil
      ColdChainReading.transaction(requires_new: true) do
        result = write(equipment, read_at, current, min, max, by, now)
      end
      result
    end

    def write(equipment, read_at, current, min, max, by, now)
      reading = ColdChainReading.create!(cold_chain_equipment: equipment, read_at: read_at, current_c: current, min_c: min, max_c: max,
                                         recorded_by_user: by, created_at: now)
      return Result.ok(reading: reading, excursion: nil, blocked_lots: 0) unless out_of_range?(equipment, reading)

      location = equipment.stock_location
      excursion = ColdChainExcursion.create!(cold_chain_reading: reading, stock_location: location, created_at: now)
      lot_ids = lots_to_block(location, now.in_time_zone.to_date)
      lot_ids.each { |lot_id| StockLotBlock.create!(cold_chain_excursion: excursion, stock_location: location, stock_lot_id: lot_id) }
      DomainEvents.publish("vaccination.cold_chain_excursion", cold_chain_excursion_id: excursion.id, stock_location_id: location.id,
                                                               user_id: by.id)
      Result.ok(reading: reading, excursion: excursion, blocked_lots: lot_ids.size)
    end

    def out_of_range?(equipment, reading)
      [ reading.current_c, reading.min_c, reading.max_c ].any? { |value| value < equipment.min_c || value > equipment.max_c }
    end

    # Lotes não vencidos com saldo > 0 no local ou com frasco aberto na sala dele.
    def lots_to_block(location, today)
      stocked = StockMovement.where(stock_location_id: location.id).group(:stock_lot_id).having("SUM(quantity) > 0").pluck(:stock_lot_id)
      room = VaccineRoom.find_by(stock_location_id: location.id)
      vials = room ? VialOpening.open_vials.where(vaccine_room_id: room.id).distinct.pluck(:stock_lot_id) : []
      StockLot.where(id: (stocked + vials).uniq).where(expires_on: today..).order(:id).pluck(:id)
    end

    def parse_time(raw)
      return nil unless raw.is_a?(String)

      Time.iso8601(raw).in_time_zone
    rescue ArgumentError
      nil
    end

    def problem(path, error) = { path: path, error: error.to_s }

    def failure(problems)
      first = problems.first
      Result.fail(first[:error], details: { path: first[:path], problems: problems })
    end

    private_class_method :write, :out_of_range?, :lots_to_block, :parse_time, :problem, :failure
  end
end
