# /billing/settings (contrato §6 com B10): admin municipal; GET sem step-up
# (nada sensível), PUT com step-up.
module Billing
  class SettingsController < BaseController
    before_action { forbid unless Access.admin?(Current.user) }

    def show = render(json: Json.settings(BillingSetting.current))

    def update
      return require_step_up! unless reauthenticated_recently?

      result = SaveSettings.call(params: params.to_unsafe_h.slice(*%w[origin_name origin_acronym origin_cnpj destination_body management]),
                                 by: Current.user)
      return render_failure(result) if result.failure?

      render json: Json.settings(result.payload[:settings])
    end
  end
end
