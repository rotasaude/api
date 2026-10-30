# GET /pharmacy/positions (contrato §4 e H10/H12): a posição de estoque por
# (local, item), em ordem estável com cursor opaco. Sem trilha e sem dado
# pessoal. Quem lê: qualquer papel do local; o almoxarife do central lê todos.
#
# `location_id` (opcional): sem ele, todos os locais que o usuário lê (o
# almoxarife do central, todos os ativos; os demais, os seus); com ele, local
# existente, senão 422; sem papel nele → 403. Filtros: `catalog_item_id`
# (uuid), `q` (nome; 2 a 60 caracteres, resolvido em ids pela busca do catálogo
# ANTES da consulta), `expiring` e `below_minimum` (`true`/`false`; `false` =
# ausente), `before` (cursor) e `limit`. Todo 422 traz `problems`.
module Pharmacy
  class PositionsController < BaseController
    include LocationReading

    FLAGS = { "true" => true, "false" => false }.freeze

    def index
      return unless query_only!(:location_id, :q, :catalog_item_id, :expiring, :below_minimum, :before, :limit)

      location_ids = readable_location_ids or return
      expiring = flag(:expiring)
      below_minimum = flag(:below_minimum)
      return render_refusal(expiring.nil? ? "expiring" : "below_minimum") if expiring.nil? || below_minimum.nil?

      item_id = params[:catalog_item_id]
      return render_refusal("catalog_item_id") if params.key?(:catalog_item_id) && !uuid?(item_id)

      limit = page_limit or return
      cursor = params.key?(:before) ? Cursor.decode(params[:before]) : nil
      return render_refusal("before", "invalid_cursor") if params.key?(:before) && !(cursor && cursor.size == 2 && cursor.all? { |part| uuid?(part) })

      item_ids = item_ids_for(item_id)
      return if performed?
      return render json: { positions: [], next_before: nil } if item_ids&.empty?

      render json: Positions.call(location_ids: location_ids, catalog_item_ids: item_ids, expiring: expiring, below_minimum: below_minimum,
                                  before: cursor, limit: limit, today: Time.zone.today, settings: Settings.current)
    end

    private

    # true | false | nil (valor inválido). Ausente e "false" valem false.
    def flag(key)
      return false unless params.key?(key)

      raw = params[key]
      raw.is_a?(String) ? FLAGS[raw] : nil
    end

    # nil: sem filtro de item; Array: ids permitidos (vazio: nada a listar).
    # Com `q` inválido ou catálogo fora, responde 422/503 (quem chama confere
    # `performed?`).
    def item_ids_for(item_id)
      ids = uuid?(item_id) ? [ item_id ] : nil
      return ids unless params.key?(:q) && params[:q].to_s.strip.present?

      q = params[:q]
      unless q.is_a?(String) && q.strip.length.between?(Medications::Search::MIN_QUERY, Catalog::SEARCH_QUERY_MAX)
        return render_refusal("q")
      end

      found = Medications::Search.call(q: q.strip).map { |hit| hit.fetch(:id) }
      ids ? found & ids : found
    rescue Medications::Search::Unavailable
      render_error(:catalog_unavailable, :service_unavailable)
    end
  end
end
