# Entrada na fila de envio à RNDS (ADR 0047, Desvios 12 e 13): uma por dose
# (`application`) e por cancelamento (`cancellation`). Nasce `pending`, com
# payload nulo (o job valida, monta e cifra), próxima tentativa agora e o
# prazo do alerta: aplicação = applied_at + 24 h; transcrição e cancelamento =
# criação + 24 h. Idempotente pelo índice único (immunization_id, kind): a
# segunda chamada não cria nada e devolve nil. Quem chama decide se o
# cancelamento entra (original rejected/failed não gera envio — Task 9).
module Rnds
  module Enqueue
    KINDS = %w[application cancellation].freeze

    module_function

    # -> RndsOutboxEntry (criada agora) | nil (já existia)
    def call(immunization, kind:, now: Time.current)
      raise ArgumentError, "unknown rnds outbox kind" unless KINDS.include?(kind)

      start = kind == "application" && !immunization.transcription ? immunization.applied_at : now
      row = { immunization_id: immunization.id, kind: kind, status: "pending", attempts: 0, next_attempt_at: now,
              deadline_at: start + Vaccination::Catalog::DEADLINE, created_at: now, updated_at: now }
      id = RndsOutboxEntry.insert_all([ row ], unique_by: :idx_rnds_outbox_immunization, returning: [ :id ]).rows.first&.first
      id && RndsOutboxEntry.find(id)
    end
  end
end
