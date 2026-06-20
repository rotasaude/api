# apps/api/app/jobs/concerns/tenant_scoped_job.rb
# Wrapper de tenant para jobs (ADR-0020). Use em todo job que toca dado
# de domínio (consumer ou job operacional). Falha fechada: sem tenant,
# levanta — não vaza.
module TenantScopedJob
  extend ActiveSupport::Concern

  class TenantMissing < StandardError; end

  private

  def with_tenant(municipality_id)
    raise TenantMissing, "#{self.class.name}: municipality_id nulo" if municipality_id.nil?

    ApplicationRecord.transaction do
      Current.municipality_id = municipality_id
      ApplicationRecord.connection.execute(
        ApplicationRecord.sanitize_sql(["SET LOCAL app.municipality_id = ?", municipality_id])
      )
      yield
    end
  end
end
