module Lab
  class LookupsController < BaseController
    before_action :provider_param!, only: %i[rejection_reasons]

    # Dashboard D14: motivos ATIVOS para o recebimento.
    def rejection_reasons
      render json: { reasons: LabRejectionReason.active.where(exam_provider_id: @provider.id).order(:name).map { |r| Lab::AdminJson.reason(r) } }
    end
  end
end
