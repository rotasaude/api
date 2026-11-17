# Vizinhos do quarteirão (módulo 35a, ADR 0054; contrato §1, §2; A-6). Só a
# coordenação (quem chama confere). O par é guardado uma vez (city_block_id <
# neighbor_block_id) e pode cruzar bairros. O mesmo quarteirão → 422
# invalid_neighbor (path neighbor_block_id); vizinho que não existe → 422
# invalid_request (path neighbor_block_id). add: par vigente repetido → ok sem
# escrita; remove: grava ended_at (par já desfeito → ok sem escrita). Os dois
# quarteirões, travados em ordem de id, ganham version + 1 e um
# city_block.changed cada (só ids). Devolve ok(block:) com o quarteirão da URL.
module VectorControl
  module LinkNeighbor
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

    module_function

    def add(block:, neighbor_block_id:, by:)
      change(block, neighbor_block_id, by) do |first, second|
        next false if CityBlockNeighbor.current.exists?(city_block_id: first.id, neighbor_block_id: second.id)

        CityBlockNeighbor.create!(city_block: first, neighbor_block: second)
        true
      end
    end

    def remove(block:, neighbor_block_id:, by:)
      change(block, neighbor_block_id, by) do |first, second|
        pair = CityBlockNeighbor.current.lock.find_by(city_block_id: first.id, neighbor_block_id: second.id)
        next false unless pair

        pair.update!(ended_at: Time.current)
        true
      end
    end

    def change(block, neighbor_block_id, by)
      id = neighbor_block_id
      return path_fail(:invalid_request) unless id.is_a?(String) && id.match?(UUID)
      return path_fail(:invalid_neighbor) if id.casecmp?(block.id)

      CityBlock.transaction(requires_new: true) do
        first, second = CityBlock.where(id: [ block.id, id ]).order(:id).lock.to_a
        next path_fail(:invalid_request) unless second

        if yield(first, second)
          [ first, second ].each do |row|
            row.update!(version: row.version + 1)
            DomainEvents.publish("city_block.changed", city_block_id: row.id, user_id: by.id)
          end
        end
        Result.ok(block: block.reload)
      end
    end

    def path_fail(reason) = Result.fail(reason, details: { path: "neighbor_block_id" })
  end
end
