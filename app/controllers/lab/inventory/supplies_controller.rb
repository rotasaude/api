# /lab/inventory/supplies (contrato §5): lê membro ou admin; cadastro só admin, com step-up.
module Lab
  module Inventory
    class SuppliesController < BaseController
      before_action :require_step_up!, only: %i[create update]
      before_action -> { provider! }, only: :index

      def index
        supplies = LabSupply.where(exam_provider_id: @provider.id).order(:name).to_a
        balances = LabSupplyMovement.joins(:lab_supply_lot).where(lab_supply_lots: { lab_supply_id: supplies.map(&:id) })
                                    .group("lab_supply_lots.lab_supply_id").sum(:quantity)
        available = Json.available_balances(supplies.map(&:id))
        render json: { supplies: supplies.map { |s| Json.supply(s, balance: balances.fetch(s.id, 0), available: available.fetch(s.id, 0)) } }
      end

      def create
        return forbid unless admin?

        provider = lab_param
        return render_failure(Result.fail(:invalid_provider)) unless provider

        respond(SaveSupply.call(body_params, provider: provider), :created)
      end

      def update
        return forbid unless admin?

        supply = uuid?(params[:id]) && LabSupply.find_by(id: params[:id])
        return not_found unless supply

        respond(SaveSupply.call(body_params, supply: supply), :ok)
      end

      private

      def respond(result, status)
        return render_failure(result) if result.failure?

        render json: Json.supply(result.payload[:supply]), status: status
      end
    end
  end
end
