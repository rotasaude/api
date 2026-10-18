# /lab/inventory/lots (contrato §5): lotes do item (ou do laboratório), com
# saldo; entrada de lote por membro do laboratório ou admin. Item de outro
# laboratório: 404 (C-E25); laboratório alheio no provider_id: 403.
module Lab
  module Inventory
    class LotsController < BaseController
      def index
        scope = if params.key?(:supply_id)
                  supply = readable_supply(params[:supply_id])
                  return not_found unless supply

                  LabSupplyLot.where(lab_supply_id: supply.id)
                elsif params.key?(:provider_id)
                  provider = lab_param
                  return not_found unless provider
                  return forbid unless reader?(provider.id)

                  LabSupplyLot.joins(:lab_supply).where(lab_supplies: { exam_provider_id: provider.id })
                else
                  return render_failure(Result.fail(:filter_required))
                end
        balances = LabSupplyMovement.where(lab_supply_lot_id: scope.select(:id)).group(:lab_supply_lot_id).sum(:quantity)
        lots = scope.includes(:lab_supply).order(:expires_on, :lot_number).to_a
        lots = lots.select { |l| balances.fetch(l.id, 0).positive? } if params[:with_balance] == "true"
        render json: { lots: lots.map { |l| Json.lot(l, balance: balances.fetch(l.id, 0)) } }
      end

      def create
        return not_found unless readable_supply(params[:supply_id])

        result = ReceiveLot.call(body_params, by: Current.user)
        return render_failure(result) if result.failure?

        render json: Json.lot(result.payload[:lot].reload), status: :created
      end
    end
  end
end
