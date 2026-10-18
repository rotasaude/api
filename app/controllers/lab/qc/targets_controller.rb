# /lab/qc/targets (contrato §3): vigentes e histórico do lote (leitura);
# referência da bula (admin ou RT/substituto, step-up).
module Lab
  module Qc
    class TargetsController < BaseController
      before_action :require_step_up!, only: %i[create accept]

      def index
        lot = uuid?(params[:lot_id]) && LabQcLot.find_by(id: params[:lot_id])
        return not_found unless lot && reader?(lot.lab_qc_material.exam_provider_id) # C-E36

        history = LabQcTarget.where(lab_qc_lot_id: lot.id).includes(:accepted_by_user).order(:analyte_key, :level, :lab_instrument_id, :version).to_a
        current = history.group_by { |t| [ t.analyte_key, t.level, t.lab_instrument_id ] }.values.map(&:last)
        render json: { current: current.map { |t| Json.target(t) }, history: history.map { |t| Json.target(t) } }
      end

      def create
        lot = uuid?(params[:lot_id]) && LabQcLot.find_by(id: params[:lot_id])
        return not_found unless lot && reader?(lot.lab_qc_material.exam_provider_id) # C-E36
        return forbid unless configurer?(lot.lab_qc_material.exam_provider_id)

        result = CreateTarget.call(body_params, by: Current.user)
        return render_failure(result) if result.failure?

        render json: Json.target(result.payload[:target]), status: :created
      end

      def suggestions
        provider = lab_param
        return not_found unless provider
        return forbid unless releaser?(provider.id)

        render json: { suggestions: Suggestions.list(provider_id: provider.id).map { |x| suggestion_json(x) } }
      end

      def accept
        lot = uuid?(params[:lot_id]) && LabQcLot.find_by(id: params[:lot_id])
        return not_found unless lot && reader?(lot.lab_qc_material.exam_provider_id) # C-E36
        return forbid unless technical?(lot.lab_qc_material.exam_provider_id)

        result = AcceptSuggestion.call(lot_id: lot.id, level: params[:level], analyte_key: params[:analyte_key], instrument_id: params[:instrument_id],
                                       reason: params[:reason], by: Current.user)
        return render_failure(result) if result.failure?

        render json: Json.target(result.payload[:target]), status: :created
      end

      private

      def suggestion_json(x)
        { lot_id: x.lot_id, level: x.level, analyte_key: x.analyte_key, instrument_id: x.instrument_id, mean: Json.out(x.mean), sd: Json.out(x.sd),
          runs: x.runs, current_version: x.current_version, current_source: x.current_source }
      end
    end
  end
end
