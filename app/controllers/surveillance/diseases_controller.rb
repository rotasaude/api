# GET /surveillance/diseases (contrato §3): a lista da cidade (plataforma em
# vigor + locais ativas) para a vigilância, o profissional de saúde e o analista
# (K16: o filtro de doença do painel).
# Dado de catálogo, sem step-up e sem trilha.
module Surveillance
  class DiseasesController < BaseController
    before_action { forbid unless surveillance? || Current.user.has_role?("health_professional") || Current.user.has_role?("analyst") }

    def index = render(json: { diseases: Diseases.all.map(&:to_json_hash) })
  end
end
