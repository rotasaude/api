# /lab/qc/reviews (contrato §3): pendentes (ou decididas) por laboratório;
# decidir: RT/substituto, step-up.
module Lab
  module Qc
    class ReviewsController < BaseController
      PRELOAD = [ :decided_by_user, :lab_qc_block, { lab_requisition_item: [ :lab_requisition, { lab_exam_version: :lab_exam } ] } ].freeze

      before_action :require_step_up!, only: :decide
      before_action -> { provider! }, only: :index

      def index
        rows = LabQcReviewItem.joins(lab_qc_block: :lab_instrument).where(lab_instruments: { exam_provider_id: @provider.id })
        rows = params[:status] == "decided" ? rows.where.not(decision: "pending") : rows.where(decision: "pending")
        render json: { reviews: rows.includes(*PRELOAD).order(:created_at, :id).limit(500).map { |r| Json.review(r) } }
      end

      def decide
        review = uuid?(params[:id]) && LabQcReviewItem.find_by(id: params[:id])
        return not_found unless review

        result = DecideReview.call(review: review, decision: params[:decision].to_s, note: params[:note], by: Current.user)
        return render_failure(result) if result.failure?

        render json: Json.review(result.payload[:review], report_id: result.payload[:report_id])
      end
    end
  end
end
