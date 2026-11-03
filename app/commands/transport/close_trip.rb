# POST /transport/my_trips/:id/close (contrato §2 <trip-log>, §5; §14 T18,
# T19): o motorista fecha a viagem `in_progress` com o diário de bordo
#   { odometer_start, odometer_end, fuel: [ { liters, amount_cents, station } ],
#     expenses: [ { kind, amount_cents, note } ] }
# - odômetro inteiro em 0..9_999_999 e fim ≥ início, senão `odometer_invalid`;
# - abastecimento: litros 0 < x ≤ 1000 com até 2 casas, centavos
#   1..10_000_000, posto 1..120; despesa: `kind` ∈ EXPENSE_KINDS (sem
#   lodging, T18), centavos idem, observação até 120 (vazia → nula); até 20
#   de cada (recusas de forma todas de uma vez, `invalid_request`);
# - todo passageiro ativo com presença (e a do acompanhante) marcada, senão
#   `attendance_pending`.
# Grava transport_trip_logs (imutável), `done`, chama Tfd::FleetLegs.complete!
# na mesma transação e publica transport.trip_done (só o id). Viagem
# done/cancelled → `trip_not_open`; planned/confirmed → `invalid_transition`.
module Transport
  module CloseTrip
    LIST_MAX = 20
    LITERS_MAX = 1000
    AMOUNT_CENTS = (1..10_000_000)
    STATION = (1..Catalog::TEXT_MAX)
    FUEL_KEYS = %w[liters amount_cents station].freeze
    EXPENSE_KEYS = %w[kind amount_cents note].freeze

    module_function

    # -> Result.ok(trip:) | fail(:invalid_request | :odometer_invalid | :attendance_pending, details: { path:, problems: }) |
    #    fail(:trip_not_open | :invalid_transition)
    def call(trip:, attrs:, by:)
      attrs = attrs.to_h.stringify_keys
      TransportTrip.transaction(requires_new: true) do
        trip.lock!
        next Result.fail(:trip_not_open) if ConfirmTrip::CLOSED.include?(trip.status)
        next Result.fail(:invalid_transition) unless trip.status == "in_progress"

        odometer = odometer_problems(attrs)
        next Support.failure(odometer) if odometer.any?

        problems = []
        fuel = list(attrs["fuel"], "fuel", problems) { |item, path| fuel_item(item, path, problems) }
        expenses = list(attrs["expenses"], "expenses", problems) { |item, path| expense_item(item, path, problems) }
        next Support.refuse(problems) if problems.any?

        pending = trip.transport_trip_passengers.active.where(attendance: "pending")
                      .or(trip.transport_trip_passengers.active.where(companion_attendance: "pending"))
        next Support.refuse_with(:attendance_pending, "passengers") if pending.exists?

        TransportTripLog.create!(transport_trip: trip, odometer_start: attrs["odometer_start"], odometer_end: attrs["odometer_end"],
                                 fuel: fuel, expenses: expenses, closed_at: Time.current, closed_by_user: by)
        trip.update!(status: "done")
        Tfd::FleetLegs.complete!(trip)
        DomainEvents.publish("transport.trip_done", trip_id: trip.id)
        Result.ok(trip: trip)
      end
    end

    def odometer_problems(attrs)
      start = Support.integer(attrs["odometer_start"], Catalog::ODOMETER)
      finish = Support.integer(attrs["odometer_end"], Catalog::ODOMETER)
      problems = []
      problems << { path: "odometer_start", error: "odometer_invalid" } unless start
      problems << { path: "odometer_end", error: "odometer_invalid" } if finish.nil? || (start && finish < start)
      problems
    end

    # Ausente → []; não lista ou mais de LIST_MAX → recusa em `path`.
    def list(value, path, problems)
      return [] if value.nil?
      unless value.is_a?(Array) && value.size <= LIST_MAX
        problems << path
        return []
      end

      value.each_with_index.map do |item, index|
        item_path = "#{path}.#{index}"
        unless item.is_a?(Hash)
          problems << item_path
          next nil
        end

        yield item.stringify_keys, item_path
      end
    end

    def fuel_item(item, path, problems)
      problems.concat((item.keys - FUEL_KEYS).map { |key| "#{path}.#{key.to_s[0, 64]}" })
      liters = liters(item["liters"])
      problems << "#{path}.liters" unless liters
      cents = Support.integer(item["amount_cents"], AMOUNT_CENTS)
      problems << "#{path}.amount_cents" unless cents
      station = Support.text(item["station"], STATION)
      problems << "#{path}.station" unless station
      { "liters" => liters, "amount_cents" => cents, "station" => station }
    end

    def expense_item(item, path, problems)
      problems.concat((item.keys - EXPENSE_KEYS).map { |key| "#{path}.#{key.to_s[0, 64]}" })
      problems << "#{path}.kind" unless Catalog::EXPENSE_KINDS.include?(item["kind"])
      cents = Support.integer(item["amount_cents"], AMOUNT_CENTS)
      problems << "#{path}.amount_cents" unless cents
      note = item["note"]
      if note.nil? || (note.is_a?(String) && note.strip.empty?)
        note = nil
      elsif note.is_a?(String) && note.strip.length <= Catalog::TEXT_MAX
        note = note.strip
      else
        problems << "#{path}.note"
      end
      { "kind" => item["kind"], "amount_cents" => cents, "note" => note }
    end

    # Litros: número (não booleano) 0 < x ≤ 1000 com até 2 casas → Float; senão nil.
    def liters(value)
      return nil unless value.is_a?(Integer) || value.is_a?(Float)

      decimal = BigDecimal(value.to_s)
      return nil unless decimal.positive? && decimal <= LITERS_MAX && decimal == decimal.round(2)

      value.is_a?(Integer) ? value : decimal.to_f
    end
  end
end
