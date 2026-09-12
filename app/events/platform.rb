# Canal de auditoria platform-scope (ADR-0012). Tudo que acontece antes ou
# fora de um tenant (login, MFA, provisioning) vai por aqui — não por
# DomainEvents.publish (que exige tenant — ADR-0004).
module Platform
  def self.audit(name, **payload)
    ApplicationRecord.connected_to(role: :admin) do
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
