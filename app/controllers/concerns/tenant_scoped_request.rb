# Abre transação no request, seta Current.municipality_id e SET LOCAL.
# Esquema de falha fechada: ausência de municipality_id derruba o request
# antes de qualquer SQL (ver ADR-0019).
module TenantScopedRequest
  extend ActiveSupport::Concern

  class TenantMissing < StandardError; end

  included do
    around_action :within_tenant
  end

  class_methods do
    def skip_tenant_scope(**options)
      skip_around_action :within_tenant, **options
    end
  end

  private

  def within_tenant
    municipality = current_municipality
    raise TenantMissing, "current_municipality is nil for #{self.class}##{action_name}" if municipality.nil?

    ApplicationRecord.transaction do
      Current.municipality_id = municipality.id
      ApplicationRecord.connection.execute(
        ApplicationRecord.sanitize_sql(["SET LOCAL app.municipality_id = ?", municipality.id])
      )
      yield
    end
  end

  # Resolve o município atual a partir do header X-Municipality-Id (operators)
  # ou do único membership ativo do usuário (single-tenant users).
  def current_municipality
    return @current_municipality if defined?(@current_municipality)

    user = Current.user
    return @current_municipality = nil if user.nil?

    selected_id = request.headers["X-Municipality-Id"]

    if user.operator? && selected_id.present?
      @current_municipality = ApplicationRecord.connected_to(role: :admin) { Municipality.find(selected_id) }
      return @current_municipality
    end

    active = user.memberships.active.where.not(role: "platform_operator").where.not(municipality_id: nil)
    membership = selected_id.present? ? active.find_by(municipality_id: selected_id) : active.first
    @current_municipality = membership && ApplicationRecord.connected_to(role: :admin) { Municipality.find(membership.municipality_id) }
  end
end
