# GET/PATCH /vaccination/admin/settings (§15 V2/D4): `{ go_live_on }`. Leitura
# e escrita só do municipal_admin; escrita com step-up.
module Vaccination
  module Admin
    class SettingsController < BaseController
      before_action { forbid unless admin? }
      before_action :require_step_up!, only: :update

      def show = render(json: Json.settings(VaccinationSetting.current))

      def update
        result = SaveSettings.call(attrs: body, by: Current.user)
        return render_failure(result) if result.failure?

        render json: result.payload.fetch(:settings)
      end
    end
  end
end
