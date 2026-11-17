# Confirma a proposta de bloqueio (módulo 35a, ADR 0054; contrato §8; Q8, Q9;
# A-14; Q26(4) revista, docs afda0ea). Só a coordenação, com step-up (quem
# chama confere). Corpo `{ center_block_id, block_ids, seen_case_ids }` (Q8;
# seen_case_ids = os casos que a tela mostrou). Recusas (só a primeira):
#   - center_block_id que não é UUID de quarteirão ativo → invalid_request
#     path center_block_id;
#   - block_ids vazio, fora de lista de UUIDs, com mais de AREA_MAX ou com
#     quarteirão que não existe ou está inativo → invalid_request path
#     block_ids;
#   - seen_case_ids ausente, fora de lista de UUIDs, com repetição ou com
#     mais de CASES_MAX → invalid_request path seen_case_ids;
#   - sob a trava do bloqueio e `lock!`, fora de proposed → invalid_transition
#     path status (409; Q9);
#   - id de seen_case_ids que não é caso desta proposta → invalid_request
#     path seen_case_ids;
#   - a proposta tem caso fora de seen_case_ids (entrou depois da leitura da
#     tela) → proposal_changed (409; Q26(4)), nada muda: o dashboard relê e a
#     lista nova passa. Os casos são lidos sob a mesma trava consultiva da
#     proposta (Propose e MoveCase escrevem sob ela). A área não é conferida
#     contra o quarteirão dos casos.
# A área é block_ids mais o centro (só acréscimo); vira active com
# confirmed_at/by e version + 1. `transmission_block.confirmed` só com ids.
module VectorControl
  module Blocks
    module Confirm
      AREA_MAX = 500
      CASES_MAX = 500
      EVENT = "transmission_block.confirmed".freeze

      module_function

      # -> Result.ok(block:) | fail(:invalid_request | :invalid_transition, details: { path: }) | fail(:proposal_changed)
      def call(block:, center_block_id:, block_ids:, seen_case_ids:, by:)
        return Support.invalid("center_block_id") unless Support.uuid?(center_block_id)
        unless block_ids.is_a?(Array) && block_ids.any? && block_ids.size <= AREA_MAX && block_ids.all? { |id| Support.uuid?(id) }
          return Support.invalid("block_ids")
        end
        unless seen_case_ids.is_a?(Array) && seen_case_ids.size <= CASES_MAX && seen_case_ids.all? { |id| Support.uuid?(id) } &&
               seen_case_ids.uniq.size == seen_case_ids.size
          return Support.invalid("seen_case_ids")
        end

        TransmissionBlock.transaction(requires_new: true) do
          Support.serialize!
          block.lock!
          next Support.transition unless block.status == "proposed"

          ids = (block_ids + [ center_block_id ]).uniq
          active = CityBlock.active_blocks.where(id: ids).pluck(:id)
          next Support.invalid("center_block_id") unless active.include?(center_block_id)
          next Support.invalid("block_ids") unless (ids - active).empty?

          case_ids = block.cases.pluck(:id)
          next Support.invalid("seen_case_ids") unless (seen_case_ids - case_ids).empty?
          next Result.fail(:proposal_changed) unless (case_ids - seen_case_ids).empty?

          TransmissionBlockArea.insert_all(ids.map { |id| { transmission_block_id: block.id, city_block_id: id } })
          block.update!(status: "active", center_block_id: center_block_id, confirmed_at: Time.current, confirmed_by_user: by,
                        version: block.version + 1)
          DomainEvents.publish(EVENT, transmission_block_id: block.id, user_id: by.id)
          Result.ok(block: block)
        end
      end
    end
  end
end
