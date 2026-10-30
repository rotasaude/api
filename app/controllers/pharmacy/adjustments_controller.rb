# Inventário, perdas e vencimentos (contrato §6 e H2/H4/H12; plano do api, Task
# 7). Respostas SEM envelope, na forma <adjustment> (Pharmacy::Json). O motivo
# (texto livre) vai só no corpo, também na lista.
#
# Quem pode, em tudo (criar, decidir, ver, listar): `stock_keeper` ou `pharmacist`
# do local do ajuste. Criar, aprovar e rejeitar pedem step-up.
#
# Ordem de `create`: `location_id` (422 se não existir) → papel no local (403
# sozinho, antes de validar o corpo) → step-up (401) → local ativo (409 cedo; o
# comando confere de novo sob trava) → o comando, que junta todas as recusas em
# `problems`. Todo 422 traz `problems`. `lot_id` que não existe segue como nil: o
# comando recusa (`lot_id`) junto com o resto.
#
# Ajuste da URL (`adjustments/:id`) de outro escopo (sem papel nenhum no local
# dele), inexistente ou não-uuid → 404; com papel no local mas sem poder decidir
# (auxiliar) → 403 sozinho. O catálogo da plataforma é lido AQUI, fora da transação.
module Pharmacy
  class AdjustmentsController < BaseController
    ROLES = %w[stock_keeper pharmacist].freeze
    PRELOAD = [ { stock_location: :health_unit }, :stock_lot, { requested_by_user: :professional }, { decided_by_user: :professional } ].freeze

    before_action :load_adjustment, only: %i[show approve reject]

    def create
      location = body_location
      return unless location
      return forbid unless allowed?(location)
      return unless step_up?
      return render_failure(Result.fail(:location_inactive, details: { path: "location_id" })) unless location.active

      lot_id = body_param("lot_id")
      lot = uuid?(lot_id) ? StockLot.find_by(id: lot_id) : nil
      result = RequestAdjustment.call(location: location, lot: lot, kind: body_param("kind"), counted_quantity: body_param("counted_quantity"),
                                      quantity: body_param("quantity"), reason: body_param("reason"), by: Current.user,
                                      settings: Settings.current)
      return render_failure(result) if result.failure?

      render json: present_one(result.payload.fetch(:adjustment)), status: :created
    end

    def approve = decide("approve")
    def reject = decide("reject")

    def show
      return forbid unless allowed?(@adjustment.stock_location)

      render json: present_many([ @adjustment ]).sole
    end

    # `location_id` obrigatório e do usuário (papel de ajuste nele): os ajustes
    # do local, mais novos primeiro, com `status` opcional.
    def index
      return unless query_only!(:location_id, :status, :before, :limit)

      raw = params[:location_id]
      location = uuid?(raw) ? StockLocation.find_by(id: raw) : nil
      return render_refusal("location_id") unless location
      return forbid unless allowed?(location)

      status = params[:status]
      return render_refusal("status") if params.key?(:status) && !Catalog::ADJUSTMENT_STATUSES.include?(status)

      limit = page_limit or return
      cursor = params.key?(:before) ? Cursor.decode(params[:before]) : nil
      return render_refusal("before", "invalid_cursor") if params.key?(:before) && !valid_cursor?(cursor)

      scope = StockAdjustment.where(stock_location_id: location.id)
      scope = scope.where(status: status) if status
      scope = scope.where("(stock_adjustments.created_at, stock_adjustments.id) < (?, ?)", Time.iso8601(cursor.first), cursor.last) if cursor
      rows = scope.includes(*PRELOAD).order(created_at: :desc, id: :desc).limit(limit + 1).to_a
      page = rows.first(limit)
      render json: { adjustments: present_many(page),
                     next_before: rows.size > limit ? Cursor.encode([ page.last.created_at.utc.iso8601(6), page.last.id ]) : nil }
    end

    private

    def decide(decision)
      return forbid unless allowed?(@adjustment.stock_location)
      return unless step_up?

      result = DecideAdjustment.call(adjustment: @adjustment, decision: decision, reason: body_param("reason"), by: Current.user)
      return render_failure(result) if result.failure?

      render json: present_one(result.payload.fetch(:adjustment))
    end

    # Ajuste da URL, só se o usuário tem algum papel no local dele; senão 404
    # (não diz que existe).
    def load_adjustment
      @adjustment = uuid?(params[:id]) ? StockAdjustment.includes(*PRELOAD).find_by(id: params[:id]) : nil
      return not_found unless @adjustment
      not_found if Access.roles_at(user: Current.user, location: @adjustment.stock_location).empty?
    end

    # Local do corpo (existente); senão 422 `location_id` e nil.
    def body_location
      id = body_param("location_id")
      location = uuid?(id) ? StockLocation.find_by(id: id) : nil
      render_refusal("location_id") unless location
      location
    end

    def allowed?(location) = Access.allowed?(user: Current.user, location: location, roles: ROLES)

    # true quando o step-up vale; senão já respondeu 401 mfa_required.
    def step_up?
      require_step_up!
      !performed?
    end

    # O ajuste recém-gravado/decidido, relido com os locais, o lote e as pessoas.
    def present_one(adjustment) = present_many([ StockAdjustment.includes(*PRELOAD).find(adjustment.id) ]).sole

    # <adjustment> de cada um, com o catálogo lido numa consulta só.
    def present_many(adjustments)
      catalog = Json.catalog_for(adjustments.map { |adjustment| adjustment.stock_lot.catalog_item_id })
      adjustments.map { |adjustment| Json.adjustment(adjustment, catalog: catalog) }
    end
  end
end
