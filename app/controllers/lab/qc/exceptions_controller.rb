# /lab/qc/exceptions (contrato §3): conceder (RT/substituto, step-up); lista
# por laboratório para membros e admin (a justificativa é do laboratório).
module Lab
  module Qc
    class ExceptionsController < BaseController
      PRELOAD = [ :granted_by_user, :lab_qc_block, { lab_requisition_item: [ :lab_requisition, { lab_exam_version: :lab_exam } ] } ].freeze

      before_action :require_step_up!, only: :create
      before_action -> { provider! }, only: :index

      def index
        rows = LabQcException.joins(lab_qc_block: :lab_instrument).where(lab_instruments: { exam_provider_id: @provider.id })
        if params[:month].to_s.match?(/\A\d{4}-(0[1-9]|1[0-2])\z/) # C7: relatório do mês
          first = Date.parse("#{params[:month]}-01")
          rows = rows.where(granted_at: first.beginning_of_day..first.end_of_month.end_of_day)
        end
        rows = rows.includes(*PRELOAD).order(granted_at: :desc).limit(500)
        render json: { exceptions: rows.map { |e| Json.exception(e) } }
      end

      def create
        result = GrantException.call(block_id: params[:block_id], item_id: params[:item_id], justification: params[:justification], by: Current.user)
        return render_failure(result) if result.failure?

        render json: Json.exception(result.payload[:exception]), status: :created
      end
    end
  end
end
