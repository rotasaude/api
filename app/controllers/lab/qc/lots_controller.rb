# /lab/qc/lots (contrato §3): lista por laboratório (ou material); criar e encerrar: admin ou RT/substituto, com step-up.
module Lab
  module Qc
    class LotsController < BaseController
      before_action :require_step_up!, only: %i[create close]
      before_action -> { provider! }, only: :index

      def index
        lots = LabQcLot.joins(:lab_qc_material).where(lab_qc_materials: { exam_provider_id: @provider.id })
        lots = lots.where(lab_qc_material_id: params[:material_id]) if uuid?(params[:material_id])
        lots = lots.where(status: params[:status]) if LabQcLot::STATUSES.include?(params[:status]) # C2
        render json: { lots: lots.includes(:barcodes, :lab_qc_material).order(Arel.sql("CASE lab_qc_lots.status WHEN 'in_use' THEN 0 ELSE 1 END"), "lab_qc_lots.created_at DESC", "lab_qc_lots.id").map { |l| Json.lot(l) } }
      end

      def create
        material = uuid?(params[:material_id]) && LabQcMaterial.find_by(id: params[:material_id])
        return not_found unless material && reader?(material.exam_provider_id) # C-E36
        return forbid unless configurer?(material.exam_provider_id)

        result = CreateLot.call(body_params, by: Current.user)
        return render_failure(result) if result.failure?

        render json: Json.lot(result.payload[:lot]), status: :created
      end

      def close
        lot = uuid?(params[:id]) && LabQcLot.find_by(id: params[:id])
        return not_found unless lot && reader?(lot.lab_qc_material.exam_provider_id) # C-E36
        return forbid unless configurer?(lot.lab_qc_material.exam_provider_id)

        result = CloseLot.call(lot: lot)
        return render_failure(result) if result.failure?

        render json: Json.lot(result.payload[:lot])
      end
    end
  end
end
