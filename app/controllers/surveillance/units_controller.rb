# GET /surveillance/units (contrato §15 K4, K11): as unidades ativas para a
# tela da notificação manual (o GET /attendance/units não aceita o papel
# `surveillance`), com `notifying`. Por nome. Sem dado de pessoa, sem trilha.
module Surveillance
  class UnitsController < BaseController
    def index
      return forbid unless surveillance?

      render json: { units: HealthUnit.active_units.map do |unit|
        { id: unit.id, cnes: unit.cnes, name: unit.name, kind: unit.kind, notifying: unit.notifying }
      end }
    end
  end
end
