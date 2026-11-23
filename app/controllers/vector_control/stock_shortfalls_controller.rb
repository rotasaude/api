# /vector_control/stock_shortfalls (módulo 35a, ADR 0054; contrato §4, §12; Q8,
# Q9): as faltas de insumo do boletim.
#   - GET `?state=open|reconciled&location_id=&before=` (padrão `open`): a
#     coordenação lê todas, inclusive as `no_location` (com `location_id`, só
#     as do local); o `stock_keeper` lê as do(s) seu(s) local(is) vector_control
#     — sem `location_id`, todas as deles; com outro local → 403 missing_role.
#     Página `{ items, next_before }`, mais novas primeiro.
#   - POST `/:id/reconcile` `{ note }` (VectorControl::ReconcileShortfall):
#     devolve o VectorShortfall, sem envelope. Falta que o usuário não lê →
#     403 missing_role; inexistente → 404.
# Sem pessoa: só o produto, o local, a quantidade, a causa, a origem e o dia.
# Módulo 35b (Q11, Q17): as faltas da dose antirrábica e da coleira também;
# abre com o vector_control ou o zoonoses utilizável.
module VectorControl
  class StockShortfallsController < BaseController
    STATES = %w[open reconciled].freeze
    LIMIT = 50

    # Q11 (35b): abre com o vector_control ou o zoonoses utilizável.
    skip_before_action :require_vector_control!
    before_action :require_vector_supplies!
    before_action(only: :reconcile) { query_only! }

    def index
      return unless query_only!(:state, :location_id, :before)

      state = request.query_parameters.fetch("state", "open")
      return render_refusal("invalid_request", path: "state") unless STATES.include?(state)

      scope = readable_scope or return
      position = cursor
      return if performed?

      scope = state == "open" ? scope.open_shortfalls : scope.where.not(reconciled_at: nil)
      rows, next_before = page(scope, :created_at, limit: LIMIT, position: position)
      render json: { items: Json.shortfalls(rows), next_before: next_before }
    end

    def reconcile
      shortfall = uuid?(params[:id]) ? VectorStockShortfall.find_by(id: params[:id]) : nil
      return not_found unless shortfall

      unknown = (body.keys - %w[note]).first
      return render_refusal("invalid_request", path: unknown) if unknown

      result = ReconcileShortfall.call(shortfall: shortfall, note: body_param("note"), by: Current.user)
      return render_failure(result) if result.failure?

      render json: Json.shortfalls([ result.payload.fetch(:shortfall) ]).sole
    end

    private

    # O escopo que o usuário lê, já filtrado pelo `location_id`; nil = já respondeu.
    def readable_scope
      raw = request.query_parameters["location_id"]
      location = nil
      if request.query_parameters.key?("location_id")
        location = uuid?(raw) ? StockLocation.find_by(id: raw, kind: "vector_control") : nil
        return render_refusal("invalid_request", path: "location_id") && nil unless location
      end

      if Access.coordinator?(Current.user)
        return location ? VectorStockShortfall.where(stock_location_id: location.id) : VectorStockShortfall.all
      end

      ids = keeper_location_ids
      return forbid && nil if ids.empty? || (location && !ids.include?(location.id))

      VectorStockShortfall.where(stock_location_id: location ? [ location.id ] : ids)
    end

    def keeper_location_ids
      vector_ids = StockLocation.where(kind: "vector_control").select(:id)
      ids = StockLocationStaff.active.where(user_id: Current.user.id, role: "stock_keeper", stock_location_id: vector_ids)
                              .pluck(:stock_location_id).uniq
      ids.empty? || !Current.user.has_role?("stock_keeper") ? [] : ids
    end
  end
end
