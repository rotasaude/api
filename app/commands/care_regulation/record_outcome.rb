# Desfecho do agendamento no prestador externo (ADR 0044; contrato §7, §13 G1;
# plano do api, Desvios 8 e 11): só de `scheduled` na rede externa (estado ou
# prestador não `own`; a rede própria segue o 17 pelo AppointmentSync).
#
#   completed → Transition para `completed` (andamento e evento
#               regulation_request.completed, só ids);
#   missed    → Misses.apply! (Task 10): `missed` nunca é situação atual; a 1ª
#               falta volta a `pending` (`external`, se state_regulated), a 2ª
#               fecha o pedido (`closed`). A cota não é liberada.
module CareRegulation
  module RecordOutcome
    RESULTS = %w[completed missed].freeze

    module_function

    # -> Result.ok(request:) | fail(:invalid_request, details: { path: }) |
    # fail(:stale_version | :invalid_transition)
    def call(request:, result:, version:, by:)
      return invalid("result") unless result.is_a?(String) && RESULTS.include?(result)
      return invalid("version") unless version.is_a?(Integer)

      ApplicationRecord.transaction(requires_new: true) do
        request.lock!(Decide::LOCK)
        next Result.fail(:stale_version) if version != request.version
        next Result.fail(:invalid_transition) unless request.status == "scheduled" && ScheduleExternal.external_network?(request)

        if result == "missed"
          Misses.apply!(request: request, by: by)
        else
          transitioned = Transition.call(request: request, to: "completed", by: by, version: version)
          # A versão já foi conferida sob a trava: só falha por erro de programação.
          raise ArgumentError, "desfecho recusado: #{transitioned.reason}" unless transitioned.ok?
        end
        Result.ok(request: request)
      end
    end

    def invalid(path) = Result.fail(:invalid_request, details: { path: path })
    private_class_method :invalid
  end
end
