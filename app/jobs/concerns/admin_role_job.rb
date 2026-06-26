# Para recurring tasks cross-tenant (ADR-0019). Roda o corpo do perform
# sob a conexão admin (rota_admin, BYPASSRLS). NÃO usar em jobs que
# operam em um único tenant — esses incluem TenantScopedJob (ADR-0020).
#
# Usar SEMPRE via `prepend AdminRoleJob` (NÃO include). Com include, o
# perform do subclass aparece antes na cadeia de ancestrais e o wrap
# do módulo nunca dispara — bug latente desde Phase 1.8 que rodava todos
# os recurring jobs como rota_app em vez de rota_admin. Com prepend, o
# perform do módulo executa primeiro e chama super para a impl do subclass.
module AdminRoleJob
  def perform(*args, **kwargs)
    ApplicationRecord.connected_to(role: :admin) do
      super
    end
  end
end
