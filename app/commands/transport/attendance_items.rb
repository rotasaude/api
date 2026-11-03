# Leitura dos `items` de presença (contrato §5; §14 T18), comum à tela do
# motorista (Transport::RecordAttendance) e à correção da central
# (Transport::CorrectAttendance): `[ { passenger_id, attendance,
# companion_attendance? } ]`, 1..MAX_ITEMS, sem passageiro repetido. Todas as
# recusas de forma de uma vez (`items.N.<campo>`); depois, o passageiro tem de
# ser ATIVO desta viagem (senão not_found, 404) e o `companion_attendance` só
# vale onde há acompanhante.
module Transport
  module AttendanceItems
    MAX_ITEMS = 100
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

    Item = Data.define(:index, :passenger_id, :attendance, :companion_attendance)

    module_function

    # -> [ [Item], problems ] (paths de invalid_request)
    def parse(items, statuses:)
      return [ [], [ "items" ] ] unless items.is_a?(Array) && (1..MAX_ITEMS).cover?(items.size)

      problems = []
      seen = {}
      list = items.each_with_index.filter_map do |raw, index|
        unless raw.is_a?(Hash)
          problems << "items.#{index}"
          next
        end

        raw = raw.stringify_keys
        id = raw["passenger_id"]
        if !id.is_a?(String) || !id.match?(UUID) || seen[id]
          problems << "items.#{index}.passenger_id"
        else
          seen[id] = true
        end
        problems << "items.#{index}.attendance" unless statuses.include?(raw["attendance"])
        companion = raw["companion_attendance"]
        problems << "items.#{index}.companion_attendance" unless companion.nil? || statuses.include?(companion)
        Item.new(index: index, passenger_id: id, attendance: raw["attendance"], companion_attendance: companion)
      end
      [ list, problems ]
    end

    # Passageiros ATIVOS da viagem, travados, por id; nil se algum faltar (404).
    def load(trip, list)
      ids = list.map(&:passenger_id)
      found = trip.transport_trip_passengers.active.where(id: ids).order(:id).lock.index_by(&:id)
      found.size == ids.size ? found : nil
    end

    # `companion_attendance` mandado para quem não tem acompanhante.
    def companion_problems(list, passengers)
      list.filter_map do |item|
        "items.#{item.index}.companion_attendance" if item.companion_attendance && passengers[item.passenger_id].companion_attendance.nil?
      end
    end
  end
end
