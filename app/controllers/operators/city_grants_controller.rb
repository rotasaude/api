# Operador verificado pede para entrar numa cidade (spec §5, Plano 3B):
#
#   POST /city_grants { city_slug } → 201 { redirect_url, expires_in }
#
# Só emite o grant; a entrada (Session na cidade) e a auditoria nos dois lados
# acontecem quando a cidade o consome, em POST /session/grant.
module Operators
  class CityGrantsController < BaseController
    def create
      slug = params[:city_slug]
      city = slug.is_a?(String) ? City.find_by(slug: slug) : nil
      return render(json: { error: "unknown_city" }, status: :not_found) unless city&.servable?

      token = CityGrants.issue(city: city, kind: "operator", subject_id: current_operator.id)
      render json: { redirect_url: CityDashboardUrl.for(city, grant: token), expires_in: CityGrants::TTL.to_i },
             status: :created
    end
  end
end
