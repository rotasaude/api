# Público pronto para gravar ou contar: o formato (AudienceSchema) e, depois
# dele, as referências do recorte — bairro e unidade precisam estar ATIVOS
# (achado do plano do dashboard: desativados depois do rascunho, a prévia e o
# envio recusam em vez de contar um público que a tela não mostra mais). As
# unidades dentro dos critérios não passam por aqui: filtram histórico.
module Campaigns
  module AudienceValidation
    module_function

    def errors(input)
      found = AudienceSchema.errors(input)
      return found if found.any?

      geo = AudienceSchema.normalize(input)["geo"]
      case geo["scope"]
      when "neighborhoods"
        active = Neighborhood.active_neighborhoods.where(id: geo["neighborhood_ids"]).pluck(:id)
        geo["neighborhood_ids"].each_with_index.filter_map do |id, i|
          AudienceSchema.error("/geo/neighborhood_ids/#{i}", "inactive_or_unknown") unless active.include?(id.downcase)
        end
      when "unit"
        return [] if HealthUnit.where(active: true, id: geo["health_unit_id"]).exists?

        [ AudienceSchema.error("/geo/health_unit_id", "inactive_or_unknown") ]
      else
        []
      end
    end
  end
end
