# GET/PUT /regulation/admin/rnds_settings (módulo 26c; contrato §5, Q13, Q19):
# as configurações do envio da regulação à RNDS. Leitura: municipal_admin ou
# care_regulator; escrita só municipal_admin, com step-up. Só o gate
# `care_regulation` (da BaseController): vale antes de ligar o envio, como a
# credencial.
module CareRegulation
  module Admin
    class RndsSettingsController < BaseController
      before_action { forbid unless admin? || regulator? }
      before_action(only: :update) { forbid unless admin? }
      before_action :require_step_up!, only: :update

      def show = render(json: Json.rnds_settings(RegulationRndsSetting.current))

      def update
        result = Regulation::SaveRndsSettings.call(attrs: body, by: Current.user)
        return render_failure(result) if result.failure?

        render json: Json.rnds_settings(result.payload.fetch(:settings))
      end
    end
  end
end
