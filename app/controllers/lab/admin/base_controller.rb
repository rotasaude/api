# /lab/admin/* (contrato §3): municipal_admin; escrita com step-up.
module Lab
  module Admin
    class BaseController < Lab::BaseController
      before_action { forbid unless Lab::Access.admin?(Current.user) }
      before_action :require_step_up!, if: -> { request.post? || request.patch? || request.delete? }

      private

      def admin_provider!(id = params[:provider_id])
        @provider = uuid?(id) && Lab::Access.labs.find_by(id: id)
        render(json: { error: "invalid_provider" }, status: :unprocessable_entity) unless @provider
      end
    end
  end
end
