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

  # Operador que entrou na cidade por grant (Plano 3B) lê todos os painéis: este
  # namespace não tem escrita (critério §10).
  allow_operator_grant_access

  # Depois de require_authentication (incluído acima) e antes de qualquer
  # leitura. Papel específico por painel não é deste plano: hoje qualquer papel
  # local lê os painéis da própria cidade.
  before_action :require_city_membership
  before_action :resolve_scope

  attr_reader :period

  rescue_from Admin::Api::InvalidScope, with: :render_invalid_scope
  rescue_from Admin::NeighborhoodFilter::Invalid, with: :render_invalid_neighborhood

  private

  def require_city_membership
    return if Current.session.operator_grant?
    return if current_user.memberships.active.exists?

    render json: { error: "no_city_membership" }, status: :forbidden
  end

  def resolve_scope
    @period = Admin::Api::Period.parse(
      key:  params[:period],
      from: params[:from],
      to:   params[:to],
      tz:   Time.zone # o da cidade (api#27): CityConnection.with o instala
    )
  end

  # Filtro de bairro (ADR 0023; spec 2026-09-28 §4.3): só os cinco painéis com
  # cidadão o leem (Visão geral, Classificação, Triagens, Relatórios,
  # Conversas). Ausente = cidade inteira, sem supressão — o console admin
  # nunca o manda.
  def neighborhood_filter
    @neighborhood_filter ||= Admin::NeighborhoodFilter.parse(params[:neighborhood_id])
  end

  # as_of = instante da leitura: os painéis agregam ao vivo (ADR 0022), então
  # é também o horário de origem do dado. `filter` só nos painéis filtráveis.
  def render_envelope(data, as_of: Time.current, filter: nil)
    data = data.merge(filter: { neighborhood: filter.descriptor }) if filter
    render json: {
      data: data.deep_merge(scope_block),
      as_of: as_of.iso8601
    }
  end

  def scope_block
    {
      scope: {
        city: { slug: Current.city.slug, name: Current.city.name, uf: Current.city.uf },
        municipality: city_descriptor,
        period: @period.descriptor,
        tz: Time.zone.tzinfo.name
      }
    }
  end

  # Descritor da cidade do host. `scope.city` {slug, name, uf} é o contrato;
  # `scope.municipality` é alias DEPRECADO (id = slug, name = "Nome · UF") mantido
  # até o passo 3 do api#35. Ordem de deploy: api (expand) → dashboard/admin →
  # api (contract).
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

  def render_invalid_neighborhood(_error)
    render json: { error: "invalid_neighborhood" }, status: :unprocessable_entity
  end
end
