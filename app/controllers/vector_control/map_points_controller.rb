# GET /vector_control/map_points (módulo 35a, ADR 0054; contrato §17; Q8,
# Q13(7)): `{ map, points }` de uma camada (VectorControl::MapPoints), com o
# manifesto do mapa publicado do 24c (null sem mapa).
#   - ?layer=risk&neighborhood_id= · ?layer=ovitraps&neighborhood_id=&epi_week=
#     · ?layer=transmission&transmission_block_id=; layer ausente ou
#     desconhecida → 422 invalid_request path layer; outra chave na query →
#     422 invalid_request; id malformado ou semana fora de "YYYY-WW" → 422 com
#     o path; bairro ou bloqueio inexistente → 404;
#   - a coordenação lê as três camadas; o vector_lab só `ovitraps`; os
#     outros → 403 missing_role.
# Leitura nominal de pontos de domicílio: uma trilha territory_map por
# microárea (TerritoryRegistry::Trail.map_households_listed!, como o
# /territory/map/households do 24c), só ids. A coordenada nunca sai junto de
# caso nem de pessoa, nem vai a log ou evento.
module VectorControl
  class MapPointsController < BaseController
    def index
      user = Current.user
      return forbid unless Access.coordinator?(user) || Access.lab?(user)

      layer = request.query_parameters["layer"]
      return render_refusal("invalid_request", path: "layer") unless layer.is_a?(String) && MapPoints::LAYERS.key?(layer)
      return forbid unless layer == "ovitraps" || Access.coordinator?(user)
      return unless query_only!(:layer, *MapPoints::LAYERS.fetch(layer))

      result = MapPoints.build(layer, params: request.query_parameters)
      return render_failure(result) if result.failure?

      result.payload.fetch(:trail).each do |micro_area_id, household_ids|
        TerritoryRegistry::Trail.map_households_listed!(user: user, micro_area_id: micro_area_id, household_ids: household_ids)
      end
      render json: { map: FieldMap.published_for(Current.city.id)&.manifest, points: result.payload.fetch(:points) }
    end
  end
end
