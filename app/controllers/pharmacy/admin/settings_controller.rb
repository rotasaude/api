# GET/PATCH /pharmacy/admin/settings (contrato §3): os cinco parâmetros da
# cidade. Leitura e escrita só do municipal_admin; escrita com step-up.
module Pharmacy
  module Admin
    class SettingsController < BaseController
      before_action { forbid unless admin? }
      before_action :require_step_up!, only: :update

      def show = render(json: Json.settings(Settings.current))

      def update
        result = SaveSettings.call(attrs: body, by: Current.user)
        return render_failure(result) if result.failure?

        render json: result.payload.fetch(:settings)
      end
    end
  end
end
