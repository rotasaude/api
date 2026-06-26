# GET /admin/api/cities[/:id] — visão de plataforma (operador) das cidades
# provisionadas + resumo de atividade. Read-only (§10). Herda do BaseController:
# auth (cookie), with_admin_connection (rota_admin/BYPASSRLS → leitura
# cross-tenant) e resolve_scope (parse do period).
class Admin::Api::CitiesController < Admin::Api::BaseController
  before_action :require_operator!

  def index
    cities = Admin::CitiesQuery.call(period: @period)
    render json: { data: { cities: cities }, as_of: Time.current.iso8601 }
  end

  def show
    municipality = Municipality.find_by(id: params[:id])
    return head(:not_found) unless municipality

    detail = Admin::CityDetailQuery.call(municipality: municipality, period: @period)
    timeline = Admin::CityTimelineQuery.call(municipality: municipality)
    render json: { data: detail.merge(timeline: timeline), as_of: Time.current.iso8601 }
  end

  private

  def require_operator!
    head :forbidden unless cross_tenant?
  end
end
