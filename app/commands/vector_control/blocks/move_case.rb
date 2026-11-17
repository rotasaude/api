# Move o caso para outro bloqueio (módulo 35a, ADR 0054; contrato §8; Q8, Q9,
# Q13(9)). Só a coordenação (quem chama confere). Corpo
# `{ to_transmission_block_id }` (Q8). Recusas (só a primeira):
#   - destino que não é UUID, é o próprio bloqueio ou não existe →
#     invalid_request path to_transmission_block_id;
#   - sob a trava, os dois bloqueios travados em ordem de id e o caso
#     travado: o caso já saiu deste bloqueio → not_found; origem ou destino
#     fora de proposed/active → invalid_transition path status (409).
# Mudam o transmission_block_id e o added_by (user, Q26(2); o trigger só
# deixa job → user no mesmo UPDATE do mover); o `number` ("caso n") fica.
# `transmission_block_case.moved` só com ids (destino, origem e quem moveu).
module VectorControl
  module Blocks
    module MoveCase
      EVENT = "transmission_block_case.moved".freeze

      module_function

      # -> Result.ok(block: <destino>) | fail(:invalid_request | :not_found | :invalid_transition, details: { path: })
      def call(block:, block_case:, to_transmission_block_id:, by:)
        path = "to_transmission_block_id"
        return Support.invalid(path) unless Support.uuid?(to_transmission_block_id) && to_transmission_block_id != block.id

        TransmissionBlock.transaction(requires_new: true) do
          Support.serialize!
          target = TransmissionBlock.find_by(id: to_transmission_block_id)
          next Support.invalid(path) unless target

          [ block, target ].sort_by(&:id).each(&:lock!)
          block_case.lock!
          next Result.fail(:not_found) unless block_case.transmission_block_id == block.id
          next Support.transition unless Support::OPEN.include?(block.status) && Support::OPEN.include?(target.status)

          block_case.update!(transmission_block_id: target.id, added_by: "user", version: block_case.version + 1)
          DomainEvents.publish(EVENT, transmission_block_id: target.id, from_transmission_block_id: block.id, user_id: by.id)
          Result.ok(block: target)
        end
      end
    end
  end
end
