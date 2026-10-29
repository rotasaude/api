# POST /pharmacy/items/search (contrato §13 H2, P3): busca no catálogo CATMAT
# para quem não é profissional de saúde. `{ q }` só no CORPO; qualquer papel
# da farmácia ou o municipal_admin. Sem filtro de REMUME. Catálogo ou listas
# Anvisa ausentes → 503 catalog_unavailable. Resposta `{ items: [ <item> ] }`,
# sem dado de paciente.
module Pharmacy
  class ItemsController < BaseController
    before_action :require_pharmacy_role

    def search
      q = body_param("q")
      return render_invalid("q") unless q.is_a?(String)

      ids = Medications::Search.call(q: q).map { |hit| hit.fetch(:id) }
      catalog = Json.catalog_for(ids)
      render json: { items: ids.filter_map { |id| catalog[id] && Json.catalog_item(catalog[id]) } }
    rescue Medications::Search::Unavailable
      render_error(:catalog_unavailable, :service_unavailable)
    end

    private

    def require_pharmacy_role
      forbid unless admin? || Access.roles_by_location(Current.user).any?
    end
  end
end
