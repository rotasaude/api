# Base de todos os controllers do namespace Admin:: (read-only).
# Ver 00_PROMPT_CLAUDE_CODE.md §2 — restrições não-negociáveis.
# Auth real via cookie de sessão (ADR-0022).
#
# Responsabilidades:
#  - fronteira de auth (Authentication concern → require_authentication)
#  - resolução de escopo (current_municipality, período, timezone)
#  - envelope universal { data:, as_of: }
#
# Nenhuma rota de escrita é permitida neste namespace (critério de aceite §10).
class Admin::Api::BaseController < ApplicationController
  include Authentication

  TZ = ActiveSupport::TimeZone["America/Sao_Paulo"]

  before_action :resolve_scope

  attr_reader :current_municipality, :period

  rescue_from Admin::Api::InvalidScope, with: :render_invalid_scope

  private

  def resolve_scope
    @current_municipality = resolve_municipality
    @period = Admin::Api::Period.parse(
      key:  params[:period],
      from: params[:from],
      to:   params[:to],
      tz:   TZ
    )
  end

  # Default: o município do usuário autenticado. "all" só vale para
  # superadmin (flag cross-tenant ainda não implementada — ADR-0022 §4).
  def resolve_municipality
    requested = params[:municipality_id].to_s
    if requested == "all" && cross_tenant?
      :all
    elsif requested.present? && cross_tenant?
      Municipality.find_by(id: requested) || current_user.municipality
    else
      current_user.municipality
    end
  end

  # TODO(superadmin): cross-tenant precisa de coluna/flag em User.
  # Por ora: nunca cross-tenant. Mantém §2.2 (multi-tenancy) sem regressão.
  def cross_tenant?
    false
  end

  def render_envelope(data, as_of: Time.current)
    render json: {
      data: data.deep_merge(scope_block),
      as_of: as_of.iso8601
    }
  end

  def scope_block
    {
      scope: {
        municipality: municipality_descriptor,
        period: @period.descriptor,
        tz: TZ.name
      }
    }
  end

  def municipality_descriptor
    if @current_municipality == :all
      { id: "all", name: "Todos os municípios", cross_tenant: true }
    else
      {
        id: @current_municipality&.id,
        name: [ @current_municipality&.name, @current_municipality&.uf ].compact.join(" · "),
        cross_tenant: false
      }
    end
  end

  def render_invalid_scope(err)
    render json: { error: "invalid_scope", message: err.message }, status: :unprocessable_entity
  end

  # Helper: as_of derivado do max(updated_at) das proj. relevantes.
  def latest_metric_at(*dimensions)
    DashboardMetric
      .where(municipality_filter)
      .where(dimension: dimensions.flatten)
      .maximum(:updated_at) || Time.current
  end

  def municipality_filter
    return {} if @current_municipality == :all
    { municipality_id: @current_municipality&.id }
  end
end
