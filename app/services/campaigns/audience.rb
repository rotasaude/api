# app/services/campaigns/audience.rb
# Público de uma campanha (ADR 0024 §4.2–§4.4): recorte geográfico ∩ cada
# critério clínico ∖ revogados, tudo em SQL. Revogado (D11) = a conversa mais
# recente do cidadão (created_at, desempate por id) tem consentimento
# revogado. O mínimo conta TELEFONES distintos (D12), pela coluna cifrada
# determinística: igualdade funciona sem decifrar.
module Campaigns
  class Audience
    # Same rule lives in Ruby in app/services/campaigns/forget_revoked_recipients.rb
    # (latest conversation of the citizen decides); both must change together.
    REVOKED_SQL = <<~SQL.squish.freeze
      SELECT latest.citizen_id FROM (
        SELECT DISTINCT ON (citizen_id) id, citizen_id FROM conversations
        WHERE citizen_id IS NOT NULL
        ORDER BY citizen_id, created_at DESC, id DESC
      ) latest
      WHERE EXISTS (
        SELECT 1 FROM consents WHERE consents.conversation_id = latest.id AND consents.revoked_at IS NOT NULL
      )
    SQL

    def initialize(audience)
      @audience = AudienceSchema.normalize(audience)
    end

    def citizen_ids
      scope = geo_scope
      @audience.dig("clinical", "all").each do |criterion|
        scope = scope.where(id: Criteria.for(criterion["kind"]).relation(criterion))
      end
      scope.where("citizens.id NOT IN (#{REVOKED_SQL})").select(:id)
    end

    def summary
      people = Citizen.where(id: citizen_ids)
      { citizens: people.count, phones: people.distinct.count(:phone) }
    end

    def below_minimum?
      summary[:phones] < Campaign::MINIMUM_PHONES
    end

    def preview
      counts = summary
      counts[:phones] < Campaign::MINIMUM_PHONES ? { below_minimum: true } : counts
    end

    private

    # Cidadão sem bairro declarado só entra no recorte city.
    def geo_scope
      geo = @audience["geo"]
      case geo["scope"]
      when "city" then Citizen.all
      when "neighborhoods" then Citizen.where(neighborhood_id: geo["neighborhood_ids"])
      when "unit"
        Citizen.where(neighborhood_id: NeighborhoodCoverage.where(health_unit_id: geo["health_unit_id"]).select(:neighborhood_id))
      end
    end
  end
end
