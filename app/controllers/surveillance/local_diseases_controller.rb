# /surveillance/admin/local_diseases (contrato §3): doenças de notificação da
# cidade, só o papel `surveillance`; escrita com step-up. Corpo JSON:
# { code (só no POST), name, deadline, cid10, ciap2, repeat_after_days, active }.
module Surveillance
  class LocalDiseasesController < BaseController
    before_action { forbid unless surveillance? }
    before_action :require_step_up!, only: %i[create update]

    def index
      records = LocalNotifiableDisease.order(:name, :code).map { |r| Diseases.from_local(r).to_json_hash }
      render json: { diseases: records }
    end

    def create
      result = SaveLocalDisease.call(attrs: body, by: Current.user)
      return render_failure(result) if result.failure?

      render json: Diseases.from_local(result.payload[:disease]).to_json_hash, status: :created
    end

    def update
      record = uuid?(params[:id]) && LocalNotifiableDisease.find_by(id: params[:id])
      return not_found unless record

      result = SaveLocalDisease.call(attrs: body, by: Current.user, disease: record)
      return render_failure(result) if result.failure?

      render json: Diseases.from_local(result.payload[:disease]).to_json_hash
    end
  end
end
