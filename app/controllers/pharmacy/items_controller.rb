# POST /pharmacy/items/search (contrato §13 H2, P3): busca no catálogo CATMAT
# para quem não é profissional de saúde. `{ q }` só no CORPO, até 60 caracteres; qualquer papel
# da farmácia ou o municipal_admin. Sem filtro de REMUME. Catálogo ou listas
# Anvisa ausentes → 503 catalog_unavailable. Resposta `{ items: [ <item> ] }`,
# sem dado de paciente.
#
# Módulo 35a (Q8, D-8): `{ q, domain: "vector_control" }` busca os produtos
# ATIVOS da vigilância ambiental (código ou nome, todos os termos; `q` vazio
# traz todos), em ordem de código, como <item> com `vector_product_id` e sem
# CATMAT (Pharmacy::Json.vector_item), com o interruptor `vector_control` no
# lugar do `pharmacy`. Outro `domain` → 422 path `domain`; sem `domain`, como antes.
# Módulo 35b (Q11): o domínio vector_control abre com o vector_control ou o
# zoonoses utilizável (VectorControl::Gate.supplies_usable?) e traz também a
# vacina antirrábica e a coleira.
module Pharmacy
  class ItemsController < BaseController
    DOMAINS = [ Stock::Domain::VECTOR_CONTROL ].freeze

    skip_before_action :require_pharmacy!
    before_action :require_search_feature!
    before_action :require_pharmacy_role

    def search
      domain = body_param("domain")
      q = body_param("q")
      return render_refusal("q") unless q.is_a?(String) && q.length <= Catalog::SEARCH_QUERY_MAX
      return render json: { items: vector_items(q) } if domain

      ids = Medications::Search.call(q: q).map { |hit| hit.fetch(:id) }
      catalog = Json.catalog_for(ids)
      render json: { items: ids.filter_map { |id| catalog[id] && Json.catalog_item(catalog[id]) } }
    rescue Medications::Search::Unavailable
      render_error(:catalog_unavailable, :service_unavailable)
    end

    private

    # O interruptor do domínio pedido (lido fora da transação da cidade).
    def require_search_feature!
      domain = body_param("domain")
      return render_refusal("domain") unless domain.nil? || DOMAINS.include?(domain)
      return require_pharmacy! if domain.nil?
      return if VectorControl::Gate.supplies_usable?(Current.city)

      render json: { error: "feature_disabled", feature: VectorControl::Gate::KEY }, status: :forbidden
    end

    def require_pharmacy_role
      forbid unless admin? || Access.roles_by_location(Current.user).any?
    end

    def vector_items(q)
      tokens = Vaccination::StockPositions.fold(q).split.first(6)
      VectorProduct.active_products.order(:code, :id).select do |product|
        text = Vaccination::StockPositions.fold("#{product.code} #{product.name}")
        tokens.all? { |token| text.include?(token) }
      end.map { |product| Json.vector_item(product) }
    end
  end
end
