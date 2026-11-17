# Encerra o bloqueio ativo (módulo 35a, ADR 0054; contrato §8; Q9). Só a
# coordenação (quem chama confere). Sob a trava e `lock!`, fora de active →
# invalid_transition path status (409). Grava closed e closed_at, version + 1;
# `transmission_block.closed` só com ids.
module VectorControl
  module Blocks
    module Close
      EVENT = "transmission_block.closed".freeze

      module_function

      # -> Result.ok(block:) | fail(:invalid_transition, details: { path: "status" })
      def call(block:, by:)
        TransmissionBlock.transaction(requires_new: true) do
          Support.serialize!
          block.lock!
          next Support.transition unless block.status == "active"

          block.update!(status: "closed", closed_at: Time.current, version: block.version + 1)
          DomainEvents.publish(EVENT, transmission_block_id: block.id, user_id: by.id)
          Result.ok(block: block)
        end
      end
    end
  end
end
