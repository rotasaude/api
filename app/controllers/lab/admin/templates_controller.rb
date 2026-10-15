module Lab
  module Admin
    class TemplatesController < BaseController
      def index
        templates = LabExamTemplate.where(active: true).includes(:analytes).order(:name)
        render json: { templates: templates.map { |t| Lab::AdminJson.template(t) } }
      end
    end
  end
end
