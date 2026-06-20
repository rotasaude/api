# Canal de auditoria platform-scope (ADR-0023). Tudo que acontece antes ou
# fora de um tenant (login, MFA, provisioning) vai por aqui — não por
# DomainEvents.publish (que exige tenant — ADR-0020).
module Platform
  def self.audit(name, **payload)
    ApplicationRecord.connected_to(role: :admin) do
      # Set GUC for RLS policy evaluation (required even with BYPASSRLS in test context)
      ApplicationRecord.connection.execute(
        "SET app.municipality_id = '00000000-0000-0000-0000-000000000000'"
      )
      DomainEvent.create!(
        id: SecureRandom.uuid,
        name: name.to_s,
        payload: payload.deep_stringify_keys,
        municipality_id: nil,
        occurred_at: Time.current
      )
    end
  end
end
