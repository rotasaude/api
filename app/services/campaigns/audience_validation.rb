# Público pronto para gravar ou contar: o formato (AudienceSchema) e, depois
# dele, as referências do recorte — bairro e unidade precisam estar ATIVOS
# (achado do plano do dashboard: desativados depois do rascunho, a prévia e o
# envio recusam em vez de contar um público que a tela não mostra mais). As
# unidades dentro dos critérios não passam por aqui: filtram histórico.
module Campaigns
  module AudienceValidation
    module_function

    FEATURE_DISABLED = "feature_disabled".freeze
    CAPS_UNIT_NOT_ALLOWED = "caps_unit_not_allowed".freeze

    # `vaccination`: o interruptor já lido (fora da transação da cidade; O40).
    # Padrão: lê agora, e só se houver critério de vacinação.
    def errors(input, vaccination: vaccination_usable?(input))
      found = AudienceSchema.errors(input)
      return found if found.any?

      found = vaccination_errors(AudienceSchema.normalize(input), vaccination)
      return found if found.any?

      audience = AudienceSchema.normalize(input)
      found = caps_unit_errors(audience)
      return found if found.any?

      geo = audience["geo"]
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

    # ADR 0049 / P59: unidade CAPS nunca é público de campanha (nem recorte, nem
    # unidade dentro de critério), porque avisar "quem é do CAPS X" revela o
    # vínculo. Vale também para o que foi gravado antes da regra: o envio
    # passa por aqui e recusa.
    UNIT_KEYS = { "attendance_outcome" => "health_unit_id", "appointment_request_open" => "target_unit_id" }.freeze

    def caps_unit_errors(audience)
      refs = []
      geo = audience["geo"]
      refs << [ "/geo/health_unit_id", geo["health_unit_id"] ] if geo["scope"] == "unit"
      audience.dig("clinical", "all").each_with_index do |criterion, i|
        key = UNIT_KEYS[criterion["kind"]]
        refs << [ "/clinical/all/#{i}/#{key}", criterion[key] ] if key && criterion[key]
      end
      return [] if refs.empty?

      caps_ids = HealthUnit.where(kind: "caps", id: refs.map(&:last)).pluck(:id)
      refs.filter_map { |path, id| AudienceSchema.error(path, CAPS_UNIT_NOT_ALLOWED) if caps_ids.include?(id.to_s.downcase) }
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
    # (contrato); CAPS no público = 422 caps_unit_not_allowed com o `path` do
    # primeiro campo; o resto, 422 invalid_audience com os caminhos.
    def failure(errors)
      if errors.any? { |e| e[:message] == FEATURE_DISABLED }
        Result.fail(:feature_disabled, details: { feature: Vaccination::Gate::KEY })
      elsif errors.any? { |e| e[:message] == CAPS_UNIT_NOT_ALLOWED }
        Result.fail(:caps_unit_not_allowed, details: { path: errors.first[:path], details: errors })
      else
        Result.fail(:invalid_audience, details: { details: errors })
      end
    end
  end
end
