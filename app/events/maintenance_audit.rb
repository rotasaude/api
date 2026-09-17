# Auditoria da API de manutenção (spec §9), gravada em platform_events pelo mesmo
# canal do resto da plataforma (Platform.audit).
#
# Duas decisões que o arquivo existe para sustentar:
#
#   1. O ATOR é o id, nunca o e-mail. platform_events é governado pela Ruling
#      R18, que recusa chave com "email" — e a intenção da regra é não acumular
#      dado pessoal aqui. Quem lê resolve o login juntando com maintainers.
#   2. Nome fora da lista e outcome desconhecido levantam. Um typo em nome de
#      evento produziria um registro que nenhuma consulta encontra — auditoria
#      que ninguém acha é auditoria que não existe.
module MaintenanceAudit
  # Nomes desta fatia. Nome novo entra AQUI e em R18_PLATFORM_EVENT_NAMES
  # (spec/events/platform_event_payload_guard_spec.rb) — a suíte quebra até lá.
  NAMES = %w[
    maintenance.session.started
    maintenance.session.failed
    maintenance.session.locked
    maintenance.session.ended
    maintenance.maintainer.invited
    maintenance.maintainer.enrolled
    maintenance.maintainer.accepted
    maintenance.token.refused
  ].freeze

  OUTCOMES = %w[attempted ok rejected error].freeze

  module_function

  def record(name, outcome:, maintainer_id:, credential:, module_name:, correlation_id: SecureRandom.uuid, **fields)
    name = name.to_s
    raise ArgumentError, "evento de manutenção não declarado: #{name}" unless NAMES.include?(name)
    raise ArgumentError, "outcome desconhecido: #{outcome}" unless OUTCOMES.include?(outcome.to_s)

    payload = {
      outcome: outcome.to_s,
      module: module_name.to_s,
      maintainer_id: maintainer_id,
      credential: credential,
      correlation_id: correlation_id,
      **fields
    }

    # Cada nome é passado como literal para Platform.audit (não `name`, a
    # variável): a guarda estática de spec/events/platform_event_payload_guard_spec.rb
    # exige call site com string literal em TODO o codebase, sem exceção para
    # wrapper. NAMES continua a única fonte de verdade — este case existe só
    # para manter cada call site auditável, não para repetir a lista.
    case name
    when "maintenance.session.started"     then Platform.audit("maintenance.session.started", **payload)
    when "maintenance.session.failed"      then Platform.audit("maintenance.session.failed", **payload)
    when "maintenance.session.locked"      then Platform.audit("maintenance.session.locked", **payload)
    when "maintenance.session.ended"       then Platform.audit("maintenance.session.ended", **payload)
    when "maintenance.maintainer.invited"  then Platform.audit("maintenance.maintainer.invited", **payload)
    when "maintenance.maintainer.enrolled" then Platform.audit("maintenance.maintainer.enrolled", **payload)
    when "maintenance.maintainer.accepted" then Platform.audit("maintenance.maintainer.accepted", **payload)
    when "maintenance.token.refused"       then Platform.audit("maintenance.token.refused", **payload)
    else
      # Sem isto, um nome novo em NAMES sem branch correspondente passaria na
      # validação acima, não escreveria nada, e ainda devolveria um
      # correlation_id — quem chamou acreditaria que auditou. Numa trilha de
      # auditoria, falha alta é sempre melhor que perda silenciosa.
      raise ArgumentError, "sem branch de dispatch para #{name} — NAMES e o case saíram de sincronia"
    end

    correlation_id
  end

  # Quem agiu: sessão humana ou token de serviço (o token chega no Plano 3). O id
  # da sessão não entra: ele é o valor do cookie.
  def credential_for(session: nil, token: nil)
    return { "kind" => "token", "token_id" => token.id } if token

    raise ArgumentError, "credential_for exige session: ou token:" unless session

    { "kind" => "session" }
  end
end
