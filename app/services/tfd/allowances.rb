# Ajuda de custo do TFD pela regra federal (ADR 0048; plano, Desvio 14; §14
# T11; Ruling da Task 10 sobre as noites internadas):
#   - no trecho `done` (ida ou volta), uma linha de deslocamento por pessoa que
#     viajou: `ground_km` (frota, ônibus) = ceil(km / 50); `air_miles` =
#     ceil(km / 1,609344 / 200); `river_miles` = ceil(km / 1,852 / 27); mínimo 1;
#   - quando o SEGUNDO trecho do par fica `done` (ida e volta feitas, em
#     qualquer ordem; T38), a alimentação de cada pessoa do par: noites =
#     volta.date − ida.date; 0 → `meal_day` × 1; senão `meal_overnight` ×
#     noites, e o PACIENTE desconta as noites internado (interseção de cada
#     estada [from, to) — aberta até a volta — com [ida, volta); estada de um
#     dia só = 0); o acompanhante não desconta (gate: manual da UF); quantidade
#     0 → sem linha.
#   - "acompanhante viajou" = `companion_attendance == "boarded"` (frota) ou
#     `leg.companion` (passagem); na alimentação, só se foi na IDA do par
#     (acompanhou o paciente ao destino; T38 — quem só voltou não recebe).
# Valor: `amount_sa_cents` da SIGTAP da competência da data do trecho
# (Billing::SigtapCache; sem release ou sem o código → 0) + o complemento da
# cidade (`allowance_complements[code]`, 0 se ausente); total = (tabela +
# complemento) × quantidade. Linha imutável e única por (tfd_leg_id, person,
# kind): INSERT … ON CONFLICT DO NOTHING e releitura — o cálculo rodado de
# novo (fechamento da viagem × botão, ou a mesma chamada repetida) não duplica.
module Tfd
  module Allowances
    TRAVEL_KIND = { "fleet" => "ground_km", "bus_ticket" => "ground_km", "air" => "air_miles", "river" => "river_miles" }.freeze
    TRAVEL_KINDS = TRAVEL_KIND.values.uniq.freeze
    MEAL_KINDS = %w[meal_overnight meal_day].freeze

    module_function

    # -> ["patient"] ou ["patient", "companion"]
    def travellers(leg)
      companion = leg.mode == "fleet" ? leg.transport_trip_passenger&.companion_attendance == "boarded" : leg.companion
      companion ? Catalog::PERSONS : Catalog::PERSONS.first(1)
    end

    # Unidades de deslocamento do trecho (mínimo 1).
    def units(leg)
      km = BigDecimal(leg.distance_km.to_i)
      raw = case leg.mode
            when "air" then km / BigDecimal(Catalog::KM_PER_MILE.to_s) / Catalog::AIR_MILES_UNIT
            when "river" then km / BigDecimal(Catalog::KM_PER_NM.to_s) / Catalog::RIVER_NM_UNIT
            else km / Catalog::KM_UNIT
            end
      [ raw.ceil.to_i, 1 ].max
    end

    # -> [TfdAllowance] de deslocamento do trecho (as já gravadas inclusive).
    def for_leg!(leg, settings: Transport::Settings.current, cache: Billing::SigtapCache.new)
      kind = TRAVEL_KIND.fetch(leg.mode)
      quantity = units(leg)
      rows = travellers(leg).map { |person| row(leg, person, kind, quantity, settings, cache) }
      insert!(leg, rows, [ kind ])
    end

    # -> [TfdAllowance] de alimentação do par, gravadas na volta (as já gravadas
    # inclusive); [] enquanto a ida ou a volta não estiver feita.
    def meals!(return_leg, settings: Transport::Settings.current, cache: Billing::SigtapCache.new)
      outbound = return_leg.outbound_leg
      return [] unless return_leg.direction == "return" && outbound&.done? && return_leg.done?

      nights = (return_leg.date - outbound.date).to_i
      persons = travellers(outbound)
      rows = persons.filter_map do |person|
        if nights.zero?
          row(return_leg, person, "meal_day", 1, settings, cache)
        else
          quantity = person == "patient" ? nights - inpatient_nights(return_leg.tfd_case, outbound.date, return_leg.date) : nights
          row(return_leg, person, "meal_overnight", quantity, settings, cache) if quantity.positive?
        end
      end
      insert!(return_leg, rows, MEAL_KINDS)
    end

    # -> { table_cents:, complement_cents:, total_cents:, competence: }
    def value(code:, on:, quantity:, settings:, cache: Billing::SigtapCache.new)
      competence = on.strftime("%Y%m")
      release = cache.release(competence)
      table = (release && cache.procedure(release, code)&.amount_sa_cents).to_i
      complement = settings.allowance_complements.to_h.fetch(code, 0).to_i
      { table_cents: table, complement_cents: complement, total_cents: (table + complement) * quantity, competence: competence }
    end

    # Noites do paciente internado em [from, to): soma das interseções das estadas.
    def inpatient_nights(tfd_case, from, to)
      Array(tfd_case.inpatient_stays).sum do |stay|
        starts = [ Date.iso8601(stay["from"]), from ].max
        ends = [ stay["to"] ? Date.iso8601(stay["to"]) : to, to ].min
        [ (ends - starts).to_i, 0 ].max
      end
    end

    def row(leg, person, kind, quantity, settings, cache)
      code = SigtapCodes.code(kind: kind, person: person)
      value(code: code, on: leg.date, quantity: quantity, settings: settings, cache: cache)
        .merge(tfd_case_id: leg.tfd_case_id, tfd_leg_id: leg.id, person: person, kind: kind, sigtap_code: code, quantity: quantity)
    end

    def insert!(leg, rows, kinds)
      TfdAllowance.insert_all(rows, unique_by: :idx_tfd_allowances_once) if rows.any?
      TfdAllowance.where(tfd_leg_id: leg.id, kind: kinds).order(:person, :kind).to_a
    end
    private_class_method :row, :insert!
  end
end
