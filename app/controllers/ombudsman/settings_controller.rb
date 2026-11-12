# GET/PATCH /ombudsman/settings (ADR 0051; contrato §7): prazos e teto da
# cidade. Só o ouvidor. A leitura cria a linha se falta (Q13).
module Ombudsman
  class SettingsController < BaseController
    before_action :require_ombudsman_role!
    before_action :query_only!

    def show
      Settings.ensure_defaults!
      render json: SaveSettings.json(OmbudsmanSetting.current)
    end

    def update
      result = SaveSettings.call(attrs: body, by: Current.user)
      return render_failure(result) if result.failure?

      render json: result.payload[:settings]
    end
  end
end
