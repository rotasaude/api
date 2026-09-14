# Base de todos os controllers do namespace Admin:: (read-only).
# Auth real via cookie de sessão (ADR-0011).
#
# Responsabilidades:
#  - fronteira de auth (Authentication concern → require_authentication), que
#    roda DENTRO da conexão da cidade do host (CityResolution);
#  - gate de vínculo: sessão não basta, o usuário precisa de ao menos um
#    membership ATIVO nesta cidade (revisão 5b M3);
#  - período e timezone do escopo;
#  - envelope universal { data:, as_of: }, com o descritor da cidade.
#
# Escopo = o banco da cidade do host. Não há município a resolver nem visão
# cross-tenant (spec banco-por-cidade §5): as queries deste namespace leem o
# banco inteiro da cidade, sem filtro. O parâmetro de município que os
# frontends ainda enviam é ignorado.
#
# Nenhuma rota de escrita é permitida neste namespace (critério de aceite §10).
class Admin::Api::BaseController < ApplicationController
  include Authentication

  TZ = ActiveSupport::TimeZone["America/Sao_Paulo"]

  # Depois de require_authentication (incluído acima) e antes de qualquer
  # leitura. Papel específico por painel não é deste plano: hoje qualquer papel
  # local lê os painéis da própria cidade.
  before_action :require_city_membership
  before_action :resolve_scope

  attr_reader :period

  rescue_from Admin::Api::InvalidScope, with: :render_invalid_scope

  private

  def require_city_membership
    return if current_user.memberships.active.exists?

    render json: { error: "no_city_membership" }, status: :forbidden
  end

  def resolve_scope
    @period = Admin::Api::Period.parse(
      key:  params[:period],
      from: params[:from],
      to:   params[:to],
      tz:   TZ
    )
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
        municipality: city_descriptor,
        period: @period.descriptor,
        tz: TZ.name
      }
    }
  end

  # Descritor da cidade do host. A chave do envelope segue `municipality`, e
  # `id`/`name` seguem no formato que dashboard e admin já leem
  # (apps/*/src/lib/api.ts) — `id` agora é o slug. Renomear o contrato é dos
  # frontends (Plano 6).
  def city_descriptor
    city = Current.city
    {
      id: city.slug,
      slug: city.slug,
      name: [ city.name, city.uf ].compact.join(" · "),
      uf: city.uf
    }
  end

  def render_invalid_scope(err)
    render json: { error: "invalid_scope", message: err.message }, status: :unprocessable_entity
  end

  # Helper: as_of derivado do max(updated_at) das proj. relevantes.
  def latest_metric_at(*dimensions)
    DashboardMetric
      .where(dimension: dimensions.flatten)
      .maximum(:updated_at) || Time.current
  end
end
