# Leitura da auditoria de manutenção (spec §9). Fica fora do resolver porque a
# parte difícil é SQL sobre jsonb mais a resolução dos logins, e isso merece
# spec próprio sem passar por GraphQL.
#
# O login não está no evento (Ruling R18: o payload guarda id). Ele é resolvido
# aqui, numa consulta só — um por evento seria N+1 numa tela que lista 200.
module Maintenance
  class AuditEventsQuery
    LIMIT_MAX = 200
    LIMIT_DEFAULT = 50

    Row = Struct.new(:name, :module_name, :outcome, :occurred_at, :maintainer_id, :login, :correlation_id,
                     keyword_init: true)

    def self.call(since: nil, until_time: nil, maintainer_id: nil, module_filter: nil, outcome: nil, limit: nil)
      scope = PlatformEvent.where("name LIKE 'maintenance.%'")
      scope = scope.where(occurred_at: since..) if since
      scope = scope.where(occurred_at: ..until_time) if until_time
      scope = scope.where("payload->>'maintainer_id' = ?", maintainer_id.to_s) if maintainer_id
      scope = scope.where("payload->>'module' = ?", module_filter.to_s) if module_filter
      scope = scope.where("payload->>'outcome' = ?", outcome.to_s) if outcome

      events = scope.order(occurred_at: :desc, created_at: :desc).limit(capped(limit)).to_a
      logins = Maintainer.where(id: events.filter_map { |e| e.payload["maintainer_id"] }.uniq)
                         .pluck(:id, :email_address).to_h

      events.map do |event|
        Row.new(name: event.name, module_name: event.payload["module"], outcome: event.payload["outcome"],
                occurred_at: event.occurred_at, maintainer_id: event.payload["maintainer_id"],
                login: logins[event.payload["maintainer_id"]], correlation_id: event.payload["correlation_id"])
      end
    end

    # Teto, não erro: um cliente que peça 10.000 recebe 200, e não uma falha que
    # ele teria de tratar.
    def self.capped(limit)
      [ (limit || LIMIT_DEFAULT).to_i, LIMIT_MAX ].min.clamp(1, LIMIT_MAX)
    end
  end
end
