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

  # Subclasses (controllers de domínio) implementam current_municipality.
  # Resolução real vem do Authorization concern no Phase 4 (membership).
  def current_municipality
    raise NotImplementedError, "#{self.class} must implement #current_municipality"
  end
end
