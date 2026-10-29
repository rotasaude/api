# Falta no horário regulado (ADR 0044; contrato §7, §13 G1; plano do api,
# Desvio 8). `missed` nunca é situação atual, nem por um instante (o CHECK de
# status o recusa, e CHECK é imediato dentro da transação):
#
#   1. Transition.record_event!(missed): o andamento `missed` e o evento
#      regulation_request.missed (só ids), sem mexer em status nem em version
#      — uma linha por falta contada (record!);
#   2. misses += faltas e UMA transição (version +1):
#      - apply! (a falta tira o pedido do horário):
#        - misses >= MAX_MISSES → `closed` (evento closed; outcome "missed");
#        - senão → de volta a `pending` (ou `external`, se state_regulated),
#          sem evento de domínio novo (o missed já foi publicado), mantendo
#          requested_at e due_on; limpa data, local, observação e
#          appointment_request_id;
#      - record! sozinho: quem chama faz a transição, levando `misses` nas
#        mudanças (AppointmentSync: a falta contada quando a recepção já
#        remarcou, o cidadão já foi atendido ou cancelou).
#   A cota NÃO é liberada: a falta consome a vaga (Desvio 3).
#
# A linha `missed` do andamento é também a marca de falta já contada: o
# AppointmentSync conta as faltas da autorização vigente pelas linhas
# `missed` gravadas depois dela.
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
    def apply!(request:, by:, count: 1)
      misses = record!(request: request, by: by, count: count)
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

    # Faltas já contadas na autorização: as linhas `missed` do andamento
    # gravadas desde ela (cada autorização abre uma cadeia nova). Fonte única
    # da regra para o AppointmentSync e o Decide.
    def counted(request:, authorization:)
      RegulationRequestEvent.where(regulation_request_id: request.id, status: "missed")
                            .where(created_at: authorization.created_at..).count
    end

    # A vaga da autorização está consumida por falta (Desvio 3; Ruling do
    # controlador, fix rounds 2 e 3): cancelar depois, por quem for, não a
    # devolve.
    def consumed?(request:, authorization:) = counted(request: request, authorization: authorization).positive?

    # Grava `count` faltas no andamento (cortadas em MAX_MISSES) e devolve o
    # novo `misses`, ainda NÃO gravado: vai nas mudanças da transição seguinte.
    def record!(request:, by:, count: 1)
      request.lock!(Decide::LOCK)
      raise ArgumentError, "falta só de #{FROM.join('/')} (situação #{request.status})" unless FROM.include?(request.status)

      count = [ count, Catalog::MAX_MISSES - request.misses ].min
      raise ArgumentError, "nenhuma falta a contar" unless count.positive?

      count.times { Transition.record_event!(request: request, status: "missed", by: by) }
      request.misses + count
    end
  end
end
