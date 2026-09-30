# app/controllers/admin/api/analytics_controller.rb
# GET /admin/api/analytics/:front (ADR 0025; contratos §1). Só analyst e
# municipal_admin da cidade (D6, D12): o operador com grant NÃO lê — é a
# única leitura de /admin/api fechada a ele (desvio 3 do plano). Lê só
# analytics_daily_facts e analytics_runs; toda contagem sai por
# Analytics::Suppression, depois de somar.
class Admin::Api::AnalyticsController < Admin::Api::BaseController
  ROLES = %w[analyst municipal_admin].freeze
  QUERIES = {
    "demand" => "Analytics::DemandQuery"
  }.freeze

  # Zero ações para sessão de grant (a base libera todas).
  allow_operator_grant_access(only: [])
  # O envelope do Analytics não usa o período dos painéis ao vivo (desvio 4).
  skip_before_action :resolve_scope
  before_action :require_analytics_role

  rescue_from Analytics::Params::Invalid, with: :render_invalid_params

  def show
    front = params[:front].to_s
    parsed = Analytics::Params.new(front, params)
    status = Analytics::Status.call
    # Nunca consolidou: séries vazias (contratos §1).
    periods = status.last_succeeded_at ? parsed.periods : []
    data = { front: front, granularity: parsed.granularity, from: parsed.from.iso8601, to: parsed.to.iso8601,
             filter: parsed.filter, periods: periods.map(&:iso8601) }
    data.merge!(QUERIES.fetch(front).constantize.new(parsed, periods: periods).call)
    render json: { data: data, as_of: status.last_succeeded_at&.utc&.iso8601, stale: status.stale }
  end

  private

  # Sessão de operador por grant recebe a recusa do contrato, não o
  # operator_read_only genérico de Authentication.
  def require_authentication
    return request_authentication unless resume_session

    render json: { error: "forbidden_role" }, status: :forbidden if Current.session.operator_grant?
  end

  def require_analytics_role
    return if current_user&.memberships&.active&.exists?(role: ROLES)

    render json: { error: "forbidden_role" }, status: :forbidden
  end

  def render_invalid_params(error) = render(json: { error: error.code }, status: :unprocessable_entity)
end
