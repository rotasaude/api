# Para recurring tasks cross-tenant (ADR-0019). Roda o corpo do perform
# sob a conexão admin (rota_admin, BYPASSRLS). NÃO usar em jobs que
# operam em um único tenant — esses incluem TenantScopedJob (ADR-0020).
module AdminRoleJob
  extend ActiveSupport::Concern

  def perform(*args, **kwargs)
    ApplicationRecord.connected_to(role: :admin) do
      super
    end
  end
end
