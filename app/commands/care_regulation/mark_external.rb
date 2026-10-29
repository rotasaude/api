# Marcar um pedido de regulação como regulado pelo estado (ADR 0044; contrato
# §8, §13 G12 #7): o regulador lança o sistema (sisreg, care, cross, other) e
# o número que o estado deu, e o pedido sai da fila e da cota. Vale em
# `pending`, `returned` e `external` (senão invalid_transition).
#
# - grava state_regulated: true, o sistema e o número (os dois ou nenhum: CHECK);
# - pending/returned → external: Transition (andamento e evento
#   regulation_request.external, só ids);
# - external → external: corrige o número (e o sistema), version +1, e deixa
#   rastro: uma linha de andamento `external` (com quem fez) e o evento
#   regulation_request.external, só ids. O andamento não leva número, sistema
#   nem motivo.
#
# O número do estado nunca em log, evento nem Result de recusa.
module CareRegulation
  module MarkExternal
    FROM = %w[pending returned external].freeze

    module_function

    # -> Result.ok(request:) | fail(:invalid_request, details: { path: }) |
    # fail(:stale_version | :invalid_transition)
    def call(request:, system:, number:, version:, by:)
      return invalid("system") unless system.is_a?(String) && Catalog::EXTERNAL_SYSTEMS.include?(system)
      return invalid("number") unless number.is_a?(String) && number.match?(Catalog::EXTERNAL_NUMBER)
      return invalid("version") unless version.is_a?(Integer)

      ApplicationRecord.transaction(requires_new: true) do
        request.lock!(Decide::LOCK)
        next Result.fail(:stale_version) if version != request.version
        next Result.fail(:invalid_transition) unless FROM.include?(request.status)

        changes = { state_regulated: true, external_system: system, external_number: number }
        if request.status == "external"
          request.update!(changes.merge(version: request.version + 1))
          Transition.record_event!(request: request, status: "external", by: by)
        else
          transitioned = Transition.call(request: request, to: "external", by: by, version: version, changes: changes)
          # A versão já foi conferida sob a trava: só falha por erro de programação.
          raise ArgumentError, "marcação recusada: #{transitioned.reason}" unless transitioned.ok?
        end
        Result.ok(request: request)
      end
    end

    def invalid(path) = Result.fail(:invalid_request, details: { path: path })
    private_class_method :invalid
  end
end
