# GET /surveillance/diseases (contrato §3): a lista da cidade (plataforma em
# vigor + locais ativas) para a vigilância e para o profissional de saúde.
# Dado de catálogo, sem step-up e sem trilha.
module Surveillance
  class DiseasesController < BaseController
    before_action { forbid unless surveillance? || Current.user.has_role?("health_professional") }

    def index = render(json: { diseases: Diseases.all.map(&:to_json_hash) })
  end
end
