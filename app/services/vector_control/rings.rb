# Raio em anéis da vigilância ambiental (módulo 35a, ADR 0054; contrato §2,
# decisão 26): os quarteirões a até `rings` saltos pelo grafo de vizinhos
# vigentes (pares sem ended_at; o par pode cruzar bairros). Os de partida
# sempre entram; além deles, só quarteirões ativos, e o inativo não propaga.
# `rings: 0` = os de partida. Uma consulta por anel. É a única função de raio
# do 35a (o raio geométrico pela coordenada do 24c fica para depois, §19).
module VectorControl
  module Rings
    module_function

    def around(block_ids, rings:)
      seen = block_ids.uniq
      frontier = seen
      rings.to_i.times do
        break if frontier.empty?

        frontier = (neighbors_of(frontier) - seen)
        frontier = CityBlock.active_blocks.where(id: frontier).pluck(:id) if frontier.any?
        seen += frontier
      end
      seen
    end

    def neighbors_of(ids)
      CityBlockNeighbor.current.where(city_block_id: ids).or(CityBlockNeighbor.current.where(neighbor_block_id: ids))
                       .pluck(:city_block_id, :neighbor_block_id).flatten.uniq
    end
  end
end
