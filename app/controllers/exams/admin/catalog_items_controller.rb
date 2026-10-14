module Exams
  module Admin
    class CatalogItemsController < BaseController
      def index
        render json: { items: ExamCatalogItem.order(:sigtap_code).map { |item| Exams::AdminJson.catalog_item(item) } }
      end

      def create
        input = Exams::CatalogInput.call(body_params)
        return render_failure(input) if input.failure?

        item = ExamCatalogItem.create!(input.payload[:attrs])
        render json: Exams::AdminJson.catalog_item(item), status: :created
      rescue ActiveRecord::RecordNotUnique
        render json: { error: "duplicate_sigtap" }, status: :unprocessable_entity
      end

      def update
        item = uuid?(params[:id]) && ExamCatalogItem.find_by(id: params[:id])
        return not_found unless item

        input = Exams::CatalogInput.call(body_params, item: item)
        return render_failure(input) if input.failure?

        item.update!(input.payload[:attrs])
        render json: Exams::AdminJson.catalog_item(item)
      end
    end
  end
end
