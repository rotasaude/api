# /lab/qc/materials (contrato §3): lê membro ou admin; grava admin ou RT/substituto, com step-up.
module Lab
  module Qc
    class MaterialsController < BaseController
      before_action :require_step_up!, only: %i[create update]
      before_action -> { provider! }, only: :index

      def index
        render json: { materials: LabQcMaterial.where(exam_provider_id: @provider.id).order(:name).map { |m| Json.material(m) } }
      end

      def create
        provider = lab_param
        return render_failure(Result.fail(:invalid_provider)) unless provider
        return forbid unless configurer?(provider.id)

        respond(SaveMaterial.call(body_params, provider: provider), :created)
      end

      def update
        material = uuid?(params[:id]) && LabQcMaterial.find_by(id: params[:id])
        return not_found unless material
        return forbid unless configurer?(material.exam_provider_id)

        respond(SaveMaterial.call(body_params, material: material), :ok)
      end

      private

      def respond(result, status)
        return render_failure(result) if result.failure?

        render json: Json.material(result.payload[:material]), status: status
      end
    end
  end
end
