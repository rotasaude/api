# GET/PATCH /transport/admin/settings (contrato §3, T12). Leitura e escrita só
# do municipal_admin; escrita com step-up.
module Transport
  module Admin
    class SettingsController < BaseController
      before_action { forbid unless admin? }
      before_action :require_step_up!, only: :update

      def show = render(json: Settings.admin_json(Settings.current))

      def update
        result = SaveSettings.call(attrs: body, by: Current.user)
        return render_failure(result) if result.failure?

        render json: result.payload.fetch(:settings).merge("allowance_codes" => Settings.allowance_codes)
      end
    end
  end
end
