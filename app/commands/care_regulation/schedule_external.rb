# Agendar (ou remarcar) no prestador externo (ADR 0044; contrato §7, §13 G1,
# G7; plano do api, Desvio 11): o regulador lança a data, o local e a
# observação. Vale em
#   - `external` (regulado pelo estado);
#   - `scheduled` com state_regulated (remarcar o que o estado agendou);
#   - `authorized`/`scheduled` com autorização vigente de prestador NÃO `own`
#     (remarcar mantém a autorização e o mês: a autorização não é tocada).
# Rede própria → invalid_transition (o horário é do 17).
#
# - `at`: ISO 8601 com fuso explícito, de now - 30 dias a now + 365 dias;
# - `place` 1–200 (PLACE_MAX), `notes` até 500 (NOTES_MAX), sem espaços nas
#   pontas; a observação é cifrada;
# - Transition para `scheduled` (andamento e evento regulation_request.scheduled,
#   só ids); state_regulated é mantido (R11).
#
# Data, local e observação nunca em log, evento nem Result de recusa.
module CareRegulation
  module ScheduleExternal
    ZONED = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:\d{2})\z/
    PAST = 30.days
    FUTURE = 365.days

    module_function

    # -> Result.ok(request:) | fail(:invalid_request, details: { path: }) |
    # fail(:stale_version | :invalid_transition)
    def call(request:, at:, place:, notes:, version:, by:, now: Time.current)
      time = parse(at)
      return invalid("at") unless time && time.between?(now - PAST, now + FUTURE)

      place = place.strip if place.is_a?(String)
      return invalid("place") unless place.is_a?(String) && place.length.between?(1, Catalog::PLACE_MAX)

      notes = notes.strip.presence if notes.is_a?(String)
      return invalid("notes") unless notes.nil? || (notes.is_a?(String) && notes.length <= Catalog::NOTES_MAX)
      return invalid("version") unless version.is_a?(Integer)

      ApplicationRecord.transaction(requires_new: true) do
        request.lock!(Decide::LOCK)
        next Result.fail(:stale_version) if version != request.version
        next Result.fail(:invalid_transition) unless valid_from?(request)

        transitioned = Transition.call(request: request, to: "scheduled", by: by, version: version,
                                       changes: { scheduled_at: time, schedule_place: place, schedule_notes: notes })
        # A versão já foi conferida sob a trava: só falha por erro de programação.
        raise ArgumentError, "agendamento recusado: #{transitioned.reason}" unless transitioned.ok?

        Result.ok(request: request)
      end
    end

    # O pedido segue a rede externa (estado ou prestador não `own`)? Fonte
    # única para o agendamento e o desfecho. Chamar com o pedido travado.
    def external_network?(request)
      return true if request.state_regulated

      authorization = RegulationAuthorization.unreleased.where(regulation_request_id: request.id).order(:created_at, :id).last
      !authorization.nil? && authorization.care_offer.care_provider.kind != "own"
    end

    def valid_from?(request)
      case request.status
      when "external" then true
      when "authorized", "scheduled" then external_network?(request)
      else false
      end
    end

    def parse(value)
      return nil unless value.is_a?(String) && value.match?(ZONED)

      DateTime.iso8601(value).to_time
    rescue Date::Error
      nil
    end

    def invalid(path) = Result.fail(:invalid_request, details: { path: path })
    private_class_method :valid_from?, :parse, :invalid
  end
end
