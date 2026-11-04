# GET /psychosocial/units (contrato P4): os CAPS ativos de lotação; para
# billing_clerk, municipal_admin e analyst, todos os CAPS ativos. Sem dado de
# paciente, sem trilha.
module Psychosocial
  class UnitsController < BaseController
    def index
      user = Current.user
      all = Access.all_units?(user)
      return forbid unless all || Access.staff?(user)
      return unless query_only!

      scope = HealthUnit.where(kind: "caps", active: true)
      scope = scope.where(id: Access.staffed_unit_ids(user)) unless all
      render json: { items: scope.order(:name, :id).map { |unit| Json.unit(unit) } }
    end
  end
end
