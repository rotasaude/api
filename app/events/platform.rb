# Canal de auditoria platform-scope (ADR-0012). Tudo que acontece antes ou
# fora de uma cidade (login, MFA, provisioning) vai por aqui — não por
# DomainEvents.publish (que exige uma cidade em Current.city).
module Platform
  def self.audit(name, **payload)
    PlatformEvent.create!(
      id: SecureRandom.uuid,
      name: name.to_s,
      payload: payload.deep_stringify_keys,
      occurred_at: Time.current
    )
  end
end
