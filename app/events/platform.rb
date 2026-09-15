# Canal de auditoria platform-scope (ADR-0012), gravado em PlatformEvent no banco
# de PLATAFORMA. Só para eventos sobre objetos de plataforma: a cidade
# (municipality.provisioned, city.suspended, city.resumed, city.backed_up,
# city.archived), canais (channel.registered, channel.token_rotated,
# channel.unknown_seen) e operadores (operator.login, operator.city_access).
# Eventos sobre usuários, memberships e convites de uma cidade usam
# DomainEvents.publish dentro da conexão da cidade (Ruling R18). PlatformEvent
# recusa payload com chave de dado pessoal.
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
