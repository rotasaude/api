# Descarta a proposta de bloqueio (módulo 35a, ADR 0054; contrato §8; Q9).
# Só a coordenação (quem chama confere). Motivo ausente ou fora de 10–500
# depois do strip → invalid_request path reason (texto longo recusado, nunca
# cortado); sob a trava e `lock!`, fora de proposed → invalid_transition path
# status (409). Grava dismissed e o motivo (cifrado com a chave da cidade),
# version + 1. O motivo nunca sai em log, evento, erro nem JSON;
# `transmission_block.dismissed` só com ids.
module VectorControl
  module Blocks
    module Dismiss
      EVENT = "transmission_block.dismissed".freeze

      module_function

      # -> Result.ok(block:) | fail(:invalid_request | :invalid_transition, details: { path: })
      def call(block:, reason:, by:)
        clean = reason.is_a?(String) ? reason.strip : nil
        return Support.invalid("reason") unless clean && Catalog::NOTE.cover?(clean.length)

        TransmissionBlock.transaction(requires_new: true) do
          Support.serialize!
          block.lock!
          next Support.transition unless block.status == "proposed"

          block.update!(status: "dismissed", dismissed_reason: clean, version: block.version + 1)
          DomainEvents.publish(EVENT, transmission_block_id: block.id, user_id: by.id)
          Result.ok(block: block)
        end
      end
    end
  end
end
