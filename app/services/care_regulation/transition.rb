# Toda mudança de situação do pedido de regulação (ADR 0044; plano do api,
# Architecture): versão otimista, linha de andamento e publicação só com ids
# (regulation_request_id e user_id, nulo sem autor). O CHAMADOR já travou o
# pedido (request.lock! ou RegulationRequest.lock) e conferiu de onde a
# transição vale; aqui não há leitura de interruptor nem de dado clínico.
#
# G1 (contrato §13): `missed` nunca é situação atual (o CHECK de status o
# recusa) — Transition.call(to: "missed") levanta ArgumentError; a falta passa
# por record_event!, que só grava o andamento e publica.
module CareRegulation
  module Transition
    # "pending" serve à promoção (event: "created", Promote) e ao complemento.
    EVENT_FOR = {
      "pending" => "complemented", "external" => "external", "authorized" => "authorized", "returned" => "returned",
      "denied" => "denied", "cancelled" => "cancelled", "scheduled" => "scheduled", "completed" => "completed",
      "missed" => "missed", "closed" => "closed"
    }.freeze
    EVENTS = (EVENT_FOR.values | %w[created]).freeze

    module_function

    # -> Result.ok(request:) | fail(:stale_version)
    # `event:` quando o mesmo `to` serve a dois eventos; `publish: false` grava
    # o andamento sem evento de domínio (volta à fila depois da falta).
    def call(request:, to:, by:, reason: nil, version: nil, changes: {}, event: nil, publish: true)
      to = to.to_s
      raise ArgumentError, "missed nunca é situação atual (G1): use record_event!" if to == "missed"
      raise ArgumentError, "situação desconhecida: #{to}" unless EVENT_FOR.key?(to)
      return Result.fail(:stale_version) if !version.nil? && version != request.version

      request.update!(changes.to_h.merge(status: to, version: request.version + 1))
      record_event!(request: request, status: to, by: by, reason: reason, publish: publish, event: event)
      Result.ok(request: request)
    end

    # Só o andamento (e a publicação): não mexe em status nem em version.
    def record_event!(request:, status:, by:, reason: nil, publish: true, event: nil)
      status = status.to_s
      name = (event || EVENT_FOR.fetch(status)).to_s
      raise ArgumentError, "evento desconhecido: #{name}" unless EVENTS.include?(name)

      RegulationRequestEvent.create!(regulation_request: request, status: status, by_user: by, reason: reason)
      return unless publish

      DomainEvents.publish("regulation_request.#{name}", regulation_request_id: request.id, user_id: by&.id)
    end
  end
end
