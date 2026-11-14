# Mapa da microárea no dashboard (módulo 24c, ADR 0053; contrato §3.1, Q39).
# GET /territory/map entrega o mesmo arquivo de mapa do app, para quem lê ao
# menos uma microárea; sem trilha (o arquivo não tem dado de pessoa).
module TerritoryRegistry
  class MapsController < BaseController
    include ::FieldMapDelivery

    before_action :require_reader!

    def show
      render_field_map(FieldMap.published_for(Current.city.id))
    end

    private

    def require_reader!
      forbid unless Access.reads_households?(Current.user, home_visits: home_visits_usable?)
    end
  end
end
