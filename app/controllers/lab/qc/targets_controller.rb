# /lab/qc/targets (contrato §3): vigentes e histórico do lote (leitura);
# referência da bula (admin ou RT/substituto, step-up).
module Lab
  module Qc
    class TargetsController < BaseController
      before_action :require_step_up!, only: %i[create]

      def index
        lot = uuid?(params[:lot_id]) && LabQcLot.find_by(id: params[:lot_id])
        return not_found unless lot
        return forbid unless reader?(lot.lab_qc_material.exam_provider_id)

        history = LabQcTarget.where(lab_qc_lot_id: lot.id).includes(:accepted_by_user).order(:analyte_key, :level, :lab_instrument_id, :version).to_a
        current = history.group_by { |t| [ t.analyte_key, t.level, t.lab_instrument_id ] }.values.map(&:last)
        render json: { current: current.map { |t| Json.target(t) }, history: history.map { |t| Json.target(t) } }
      end

      def create
        lot = uuid?(params[:lot_id]) && LabQcLot.find_by(id: params[:lot_id])
        return render_failure(Result.fail(:not_found)) unless lot
        return forbid unless configurer?(lot.lab_qc_material.exam_provider_id)

        result = CreateTarget.call(body_params, by: Current.user)
        return render_failure(result) if result.failure?

        render json: Json.target(result.payload[:target]), status: :created
      end
    end
  end
end
