# GET /admin/api/municipalities — catálogo para o seletor de escopo.
# Hoje só devolve a municipalidade do admin. "all" depende de superadmin
# (flag cross-tenant não implementada, ver RECONCILE.md / §9 do brief).
class Admin::Api::MunicipalitiesController < Admin::Api::BaseController
  def index
    m = current_municipality
    list = [
      { id: m&.id, name: [ m&.name, m&.uf ].compact.join(" · "), cross_tenant: false }
    ]
    render json: { data: list, as_of: Time.current.iso8601 }
  end
end
