# Público pronto para gravar ou contar: o formato (AudienceSchema) e, depois
# dele, as referências do recorte — bairro e unidade precisam estar ATIVOS
# (achado do plano do dashboard: desativados depois do rascunho, a prévia e o
# envio recusam em vez de contar um público que a tela não mostra mais). As
# unidades dentro dos critérios não passam por aqui: filtram histórico.
module Campaigns
  module AudienceValidation
    module_function

    FEATURE_DISABLED = "feature_disabled".freeze

    # `vaccination`: o interruptor já lido (fora da transação da cidade; O40).
    # Padrão: lê agora, e só se houver critério de vacinação.
    def errors(input, vaccination: vaccination_usable?(input))
      found = AudienceSchema.errors(input)
      return found if found.any?

      found = vaccination_errors(AudienceSchema.normalize(input), vaccination)
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

    # Interruptor `vaccination` utilizável; só é consultado quando o público tem
    # critério de vacinação (nunca onera o caminho dos demais critérios).
    def vaccination_usable?(input)
      return false unless vaccination_criteria?(input)

      Vaccination::Gate.usable?(Current.city)
    end

    def vaccination_criteria?(input)
      audience = AudienceSchema.normalize(input)
      all = audience.is_a?(Hash) && audience["clinical"].is_a?(Hash) ? audience["clinical"]["all"] : nil
      all.is_a?(Array) && all.any? { |c| c.is_a?(Hash) && AudienceSchema::VACCINATION_KINDS.include?(c["kind"]) }
    end

    # Os critérios de vacinação só existem com o interruptor `vaccination` ligado.
    def vaccination_errors(audience, usable)
      return [] if usable

      audience.dig("clinical", "all").each_with_index.filter_map do |criterion, i|
        AudienceSchema.error("/clinical/all/#{i}/kind", FEATURE_DISABLED) if AudienceSchema::VACCINATION_KINDS.include?(criterion["kind"])
      end
    end

    # Recusa do público como Result: interruptor desligado = 403 feature_disabled
    # (contrato); o resto, 422 invalid_audience com os caminhos.
    def failure(errors)
      if errors.any? { |e| e[:message] == FEATURE_DISABLED }
        Result.fail(:feature_disabled, details: { feature: Vaccination::Gate::KEY })
      else
        Result.fail(:invalid_audience, details: { details: errors })
      end
    end
  end
end
