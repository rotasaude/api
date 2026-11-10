# Faltas de estoque da checagem da UPA (ADR 0050; contrato §7 e §12 Q7; plano,
# Desvio 12). Exige `pharmacy` utilizável, NÃO `urgency_stock_deduction`:
# desligar a baixa depois mantém a lista e a conciliação (Review Focus 5).
#
# Lista: com `location_id` (o nome do 27a), farmacêutico ou almoxarife do local
# ou o almoxarife do central; sem `location_id`, só o almoxarife do central, e a
# lista inclui as `no_location` de todas as UPAs. Sem nome, CPF, CNS, dose, via
# nem instruções; sem trilha (não há dado pessoal). Local de vacina → 404.
module Pharmacy
  class UrgencyShortfallsController < BaseController
    STATES = %w[open reconciled].freeze

    def index
      return unless query_only!(:location_id, :state, :before, :limit)

      state = params.fetch(:state, "open")
      return render_refusal("state") unless STATES.include?(state)

      limit = page_limit or return
      cursor = params.key?(:before) ? Cursor.decode(params[:before]) : nil
      return render_refusal("before", "invalid_cursor") if params.key?(:before) && !valid_cursor?(cursor)

      scope = UrgencyStockShortfall.all
      if params.key?(:location_id)
        location = existing_location or return
        return not_found if Stock::Domain.immunobiological?(location)
        return forbid unless ReconcileUrgencyShortfall.allowed?(user: Current.user, location: location)

        scope = scope.where(stock_location_id: location.id)
      else
        return forbid unless Access.central_keeper?(Current.user)
      end

      scope = state == "open" ? scope.open_shortfalls : scope.where.not(reconciled_at: nil)
      scope = scope.where("(urgency_stock_shortfalls.created_at, urgency_stock_shortfalls.id) < (?, ?)", Time.iso8601(cursor.first), cursor.last) if cursor
      rows = scope.order(created_at: :desc, id: :desc).limit(limit + 1).to_a
      page = rows.first(limit)
      render json: { items: present(page),
                     next_before: rows.size > limit ? Cursor.encode([ page.last.created_at.utc.iso8601(6), page.last.id ]) : nil }
    end

    def reconcile
      shortfall = uuid?(params[:id]) ? UrgencyStockShortfall.find_by(id: params[:id]) : nil
      return not_found unless shortfall

      result = ReconcileUrgencyShortfall.call(shortfall: shortfall, note: body_param("note"), by: Current.user)
      return render_failure(result) if result.failure?

      render json: { shortfall: present([ result.payload.fetch(:shortfall) ]).sole }
    end

    private

    # `location_id` da query (existente); senão 422 e nil.
    def existing_location
      raw = params[:location_id]
      location = uuid?(raw) ? StockLocation.find_by(id: raw) : nil
      render_refusal("location_id") unless location
      location
    end

    # { shortfall_id, created_at, stock_location_id, catalog_item, quantity, cause,
    #   administration: { administered_at, ticket }, reconciled_at, reconciled_by: { name } | null }
    def present(rows)
      catalog = Json.catalog_for(rows.map(&:catalog_item_id))
      administrations = UrgencyAdministration.where(id: rows.map(&:urgency_administration_id))
                                             .includes(urgency_encounter: :attendance).index_by(&:id)
      users = User.where(id: rows.filter_map(&:reconciled_by_user_id)).includes(:professional).index_by(&:id)
      rows.map do |row|
        administration = administrations.fetch(row.urgency_administration_id)
        reconciler = users[row.reconciled_by_user_id]
        { shortfall_id: row.id, created_at: row.created_at.utc.iso8601(6), stock_location_id: row.stock_location_id,
          catalog_item: Json.catalog_item(catalog.fetch(row.catalog_item_id)), quantity: Quantity.dump(row.quantity), cause: row.cause,
          administration: { administered_at: administration.administered_at&.utc&.iso8601,
                            ticket: administration.urgency_encounter.attendance.ticket },
          reconciled_at: row.reconciled_at&.utc&.iso8601,
          reconciled_by: reconciler && { name: reconciler.professional&.professional_name } }
      end
    end
  end
end
