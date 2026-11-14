# Mapa da microárea no dashboard (módulo 24c, ADR 0053; contrato §3.1; Q14,
# Q38, Q39).
#   - GET /territory/map entrega o mesmo arquivo de mapa do app, para quem lê
#     ao menos uma microárea; sem trilha (o arquivo não tem dado de pessoa).
#   - GET /territory/map/households?micro_area_id= devolve o manifesto do mapa
#     publicado (o dashboard não sonda o arquivo) e os pontos dos domicílios
#     ATIVOS da microárea que têm ponto, só com rua, número, famílias e versão.
#     Leitura nominal: uma trilha por consulta (access territory_map), só ids.
#     A coordenada nunca vai a log nem a evento.
module TerritoryRegistry
  class MapsController < BaseController
    include ::FieldMapDelivery

    before_action :require_reader!, only: :show

    def show
      # Nenhuma chave na query: nada de coordenada ou pessoa na URL.
      return unless query_only!

      render_field_map(FieldMap.published_for(Current.city.id))
    end

    def households
      return unless query_only!(:micro_area_id)
      return render_error("invalid_request") unless uuid?(params[:micro_area_id])

      area = MicroArea.find_by(id: params[:micro_area_id])
      return not_found unless area
      return forbid("out_of_scope") unless visible?(area.id, area.team)

      items = points(area)
      Trail.map_households_listed!(user: Current.user, micro_area_id: area.id, household_ids: items.map { |item| item[:id] }) if items.any?
      render json: { map: FieldMap.published_for(Current.city.id)&.manifest, items: items }
    end

    private

    def require_reader!
      forbid unless Access.reads_households?(Current.user, home_visits: home_visits_usable?)
    end

    # Os domicílios ativos da microárea cuja última versão tem ponto (Q38), por id.
    def points(area)
      households = Household.where(micro_area_id: area.id, status: "active").order(:id).to_a
      versions = HouseholdVersion.joins(:household).where(household_id: households.map(&:id))
                                 .where("household_versions.version = households.version").index_by(&:household_id)
      families = Family.where(household_id: households.map(&:id), moved_out: false).group(:household_id).count
      households.filter_map do |household|
        version = versions[household.id]
        next unless version&.location

        address = version.address.to_h
        { id: household.id, location: version.location, address: { street: address["street"], number: address["number"] },
          families_count: families.fetch(household.id, 0), version: household.version }
      end
    end
  end
end
