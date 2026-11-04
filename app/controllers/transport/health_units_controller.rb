# GET /transport/health_units (contrato §14 T46): unidades de saúde ativas da
# cidade para a central, ordenadas pelo nome. `{ units: [ { id, name } ] }`,
# sem outros campos. Sem trilha, sem evento.
module Transport
  class HealthUnitsController < BaseController
    before_action { forbid unless Access.dispatcher?(Current.user) }

    def index
      return unless query_only!

      units = HealthUnit.where(active: true).order(:name, :id).pluck(:id, :name)
      render json: { units: units.map { |id, name| { id: id, name: name } } }
    end
  end
end
