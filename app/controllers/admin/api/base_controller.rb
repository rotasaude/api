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
  # Admin tem resolução de escopo própria (suporta "all" cross-tenant para
  # operador, agregações por município, descritor de escopo no envelope).
  # Por isso pula o around_action :within_tenant herdado de
  # TenantScopedRequest (ADR-0019). Queries de dado de domínio rodam sob
  # rota_admin (BYPASSRLS) porque o WHERE muni_id de Admin::Scoped não
  # desativa a RLS policy — sem SET LOCAL elas levantam UndefinedObject
  # em qualquer tabela RLS-enforced. Como o namespace é read-only por
  # critério §10 e o escopo por município é aplicado por código, o BYPASS
  # é seguro aqui.
  skip_tenant_scope
  around_action :with_admin_connection

  include Authentication

  TZ = ActiveSupport::TimeZone["America/Sao_Paulo"]

  before_action :resolve_scope

  attr_reader :current_municipality, :period

  rescue_from Admin::Api::InvalidScope, with: :render_invalid_scope

  private

  def with_admin_connection
    ApplicationRecord.connected_to(role: :admin) { yield }
  end

  def resolve_scope
    @current_municipality = resolve_municipality
    @period = Admin::Api::Period.parse(
      key:  params[:period],
      from: params[:from],
      to:   params[:to],
      tz:   TZ
    )
  end

  # Resolução por membership (Phase 4.2/4.5):
  # - operador + "all"                  → :all (cross-tenant)
  # - operador + ?municipality_id=<id>  → essa cidade
  # - municipal_admin (ou similar)      → única cidade do membership ativo
  def resolve_municipality
    requested = params[:municipality_id].to_s
    if requested == "all" && cross_tenant?
      :all
    elsif requested.present? && cross_tenant?
      Municipality.find_by(id: requested) || first_member_municipality
    else
      first_member_municipality
    end
  end

  # Operador (platform_operator membership) pode atravessar tenants.
  def cross_tenant?
    Current.user&.operator? || false
  end

  def first_member_municipality
    membership = Current.user&.memberships
                       &.active
                       &.where&.not(role: "platform_operator")
                       &.where&.not(municipality_id: nil)
                       &.first
    return nil unless membership&.municipality_id
    Municipality.find_by(id: membership.municipality_id)
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
