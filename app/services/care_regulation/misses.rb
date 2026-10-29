# Falta no horário regulado (ADR 0044; contrato §7, §13 G1; plano do api,
# Desvio 8). `missed` nunca é situação atual, nem por um instante (o CHECK de
# status o recusa, e CHECK é imediato dentro da transação):
#
#   1. Transition.record_event!(missed): o andamento `missed` e o evento
#      regulation_request.missed (só ids), sem mexer em status nem em version;
#   2. misses += 1 e UMA transição (version +1):
#      - misses >= MAX_MISSES → `closed` (evento closed; outcome "missed");
#      - senão → de volta a `pending` (ou `external`, se state_regulated), sem
#        evento de domínio novo (o missed já foi publicado), mantendo
#        requested_at e due_on.
#   Nos dois casos limpa data, local, observação e appointment_request_id. A
#   cota NÃO é liberada: a falta consome a vaga (Desvio 3).
#
# O chamador já está numa transação e travou o pedido; aqui a trava é
# retomada com o mesmo FOR NO KEY UPDATE do Decide (lock! relê a linha: o
# chamador não deixa mudança em memória). Na rede própria, encerrar o pedido
# de agendamento reaberto pelo Lapse é do chamador (AppointmentSync), na mesma
# transação, depois desta chamada.
module CareRegulation
  module Misses
    FROM = %w[authorized scheduled].freeze

    module_function

    # -> RegulationRequest (já na situação nova).
    def apply!(request:, by:)
      request.lock!(Decide::LOCK)
      raise ArgumentError, "falta só de #{FROM.join('/')} (situação #{request.status})" unless FROM.include?(request.status)

      Transition.record_event!(request: request, status: "missed", by: by)
      misses = request.misses + 1
      changes = { misses: misses, scheduled_at: nil, schedule_place: nil, schedule_notes: nil, appointment_request_id: nil }
      transitioned =
        if misses >= Catalog::MAX_MISSES
          Transition.call(request: request, to: "closed", by: by, changes: changes)
        else
          Transition.call(request: request, to: request.state_regulated ? "external" : "pending", by: by, changes: changes,
                          publish: false)
        end
      # Sem versão a conferir: só falha por erro de programação.
      raise ArgumentError, "falta recusada: #{transitioned.reason}" unless transitioned.ok?

      request
    end
  end
end
