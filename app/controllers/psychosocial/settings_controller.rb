# GET/PATCH /psychosocial/settings (contrato §3, P33): leitura pelo
# municipal_admin e pela coordenação do CAPS (o mapa de leitos mostra o
# limite); escrita só do municipal_admin, com step-up.
module Psychosocial
  class SettingsController < BaseController
    before_action :require_reader, only: :show
    before_action :require_admin, only: :update
    before_action :require_step_up!, only: :update

    def show = render(json: Settings.json(Settings.current))

    def update
      result = SaveSettings.call(attrs: body, by: Current.user)
      return render_failure(result) if result.failure?

      render json: result.payload.fetch(:settings)
    end

    private

    def require_reader = (forbid unless admin? || Access.lead?(Current.user))
    def require_admin = (forbid unless admin?)
  end
end
