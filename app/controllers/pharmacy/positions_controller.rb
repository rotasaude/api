# GET /pharmacy/positions (contrato §4 e H10/H12): a posição de estoque por
# (local, item), em ordem estável com cursor opaco. Sem trilha e sem dado
# pessoal. Quem lê: qualquer papel do local; o almoxarife do central lê todos.
#
# `location_id` (opcional): sem ele, todos os locais que o usuário lê (o
# almoxarife do central, todos os ativos; os demais, os seus); com ele, local
# existente, senão 422; sem papel nele → 403. Filtros: `catalog_item_id`
# (uuid), `q` (nome; 2 a 60 caracteres, resolvido em ids ANTES da consulta,
# entre os itens com posição nos locais lidos: sem limite e sem o filtro de
# item "prescritível"), `expiring` e `below_minimum` (`true`/`false`; `false` =
# ausente), `before` (cursor) e `limit`. Todo 422 traz `problems`.
#
# Módulo 29 (Desvio 5; §15 V4/V18): local de vacina → Vaccination::StockPositions
# (mesma forma, <item> de imunobiológico, `blocked` por lote, sem mínimos), com
# o interruptor `vaccination`. Sem `location_id`, os locais lidos são só os de
# medicamento, como antes do 29 (com `pharmacy` desligado → 403
# feature_disabled pharmacy): o local de vacina pede `location_id`. Na
# vacina, `catalog_item_id` não casa nada, `below_minimum=true` não casa nada
# (sem mínimos) e `q` casa o nome do catálogo da sala; o cursor é
# `[location_id, código]`.
module Pharmacy
  class PositionsController < BaseController
    include LocationReading

    FLAGS = { "true" => true, "false" => false }.freeze
    IMMUNOBIOLOGICAL_CODE = /\A\d{1,10}\z/

    skip_before_action :require_pharmacy!
    before_action :require_stock_feature!

    def index
      return unless query_only!(:location_id, :q, :catalog_item_id, :expiring, :below_minimum, :before, :limit)

      locations = positions_locations or return
      location_ids = locations.map(&:id)
      immunobiological = Stock::Domain.immunobiological?(locations.first)
      expiring = flag(:expiring)
      below_minimum = flag(:below_minimum)
      return render_refusal(expiring.nil? ? "expiring" : "below_minimum") if expiring.nil? || below_minimum.nil?

      item_id = params[:catalog_item_id]
      return render_refusal("catalog_item_id") if params.key?(:catalog_item_id) && !uuid?(item_id)

      limit = page_limit or return
      cursor = params.key?(:before) ? Cursor.decode(params[:before]) : nil
      return render_refusal("before", "invalid_cursor") if params.key?(:before) && !valid_position_cursor?(cursor, immunobiological)
      return vaccine_positions(location_ids, expiring: expiring, below_minimum: below_minimum, cursor: cursor, limit: limit) if immunobiological

      item_ids = item_ids_for(item_id, location_ids)
      return if performed?
      return render json: { positions: [], next_before: nil } if item_ids&.empty?

      render json: Positions.call(location_ids: location_ids, catalog_item_ids: item_ids, expiring: expiring, below_minimum: below_minimum,
                                  before: cursor, limit: limit, today: Time.zone.today, settings: Settings.current)
    end

    private

    # Locais lidos (todos do mesmo domínio): o `location_id` (legível e com o
    # interruptor do domínio) ou os do usuário. nil = já respondeu.
    def positions_locations
      if params.key?(:location_id)
        location = required_location or return nil
        return stock_feature_for!(location) ? [ location ] : nil
      end

      require_pharmacy!
      return nil if performed?

      locations = Access.locations_for(Current.user)
      return forbid && nil if locations.empty?

      locations
    end

    # [location_id, catalog_item_id] (dois uuids) ou, na vacina, [location_id, código].
    def valid_position_cursor?(cursor, immunobiological)
      return false unless cursor && cursor.size == 2 && uuid?(cursor.first)

      immunobiological ? cursor.last.is_a?(String) && cursor.last.match?(IMMUNOBIOLOGICAL_CODE) : uuid?(cursor.last)
    end

    def vaccine_positions(location_ids, expiring:, below_minimum:, cursor:, limit:)
      codes = nil
      codes = [] if params.key?(:catalog_item_id) || below_minimum
      if params.key?(:q) && params[:q].to_s.strip.present?
        q = params[:q]
        return render_refusal("q") unless q.is_a?(String) && q.strip.length.between?(Medications::Search::MIN_QUERY, Catalog::SEARCH_QUERY_MAX)

        matched = Vaccination::StockPositions.codes_matching(q.strip)
        codes = codes ? codes & matched : matched
      end
      return render json: { positions: [], next_before: nil } if codes&.empty?

      render json: Vaccination::StockPositions.call(location_ids: location_ids, codes: codes, expiring: expiring, before: cursor, limit: limit,
                                                    today: Time.zone.today, settings: Settings.current)
    end

    # true | false | nil (valor inválido). Ausente e "false" valem false.
    def flag(key)
      return false unless params.key?(key)

      raw = params[key]
      raw.is_a?(String) ? FLAGS[raw] : nil
    end

    # nil: sem filtro de item; Array: ids permitidos (vazio: nada a listar).
    # O `q` é resolvido por Positions.item_ids_matching, entre os itens que têm
    # posição nos locais lidos (sem limite e sem o filtro "prescritível" da
    # busca do catálogo). `q` inválido responde 422 (quem chama confere
    # `performed?`).
    def item_ids_for(item_id, location_ids)
      ids = uuid?(item_id) ? [ item_id ] : nil
      return ids unless params.key?(:q) && params[:q].to_s.strip.present?

      q = params[:q]
      unless q.is_a?(String) && q.strip.length.between?(Medications::Search::MIN_QUERY, Catalog::SEARCH_QUERY_MAX)
        return render_refusal("q")
      end

      Positions.item_ids_matching(q: q.strip, location_ids: location_ids, item_ids: ids)
    end
  end
end
