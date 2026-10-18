# /lab/inventory/movements (contrato §5): histórico do lote; saída e
# acerto por membro ou admin (ajuste só admin, com step-up). Lote de outro
# laboratório: 404 (C-E25).
module Lab
  module Inventory
    class MovementsController < BaseController
      before_action :load_lot

      def index
        # C8: do mais novo ao mais antigo.
        movements = @lot.movements.includes(:recorded_by_user).reorder(recorded_at: :desc, created_at: :desc, id: :desc)
        render json: { movements: movements.map { |m| Json.movement(m) } }
      end

      def create
        if params[:kind] == "adjustment"
          return forbid unless admin?
          return require_step_up! unless reauthenticated_recently?
        end
        result = RecordMovement.call(lot: @lot, kind: params[:kind].to_s, quantity: params[:quantity], reason: params[:reason],
                                     by: Current.user, admin: admin?)
        return render_failure(result) if result.failure?

        render json: Json.movement(result.payload[:movement], balance: result.payload[:balance]), status: :created
      end

      private

      def load_lot
        @lot = uuid?(params[:lot_id]) && LabSupplyLot.includes(:lab_supply).find_by(id: params[:lot_id])
        not_found unless @lot && reader?(@lot.lab_supply.exam_provider_id)
      end
    end
  end
end
