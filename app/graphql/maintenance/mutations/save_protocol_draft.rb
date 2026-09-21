module Maintenance
  module Mutations
    class SaveProtocolDraft < CityMutation
      description "Salva uma versão de protocolo em rascunho numa cidade. O mantenedor passa a " \
                  "constar como quem editou a versão, e quem edita nunca a assina."

      argument :definition, GraphQL::Types::JSON, required: true

      def resolve(city_slug:, definition:)
        definition = definition.to_h.deep_stringify_keys

        # `protocol_key` e `version` vão para a auditoria de plataforma: só
        # entram se forem o que dizem ser — um nome (String) e um número
        # (Integer). Qualquer outra coisa é recusada ANTES de auditar, para
        # que nenhuma estrutura arbitrária do cliente chegue a platform_events.
        unless definition["name"].is_a?(String) && definition["version"].is_a?(Integer)
          return { ok: false, errors: [ { path: "definition", message: "definition exige name (texto) e version (inteiro)" } ] }
        end

        in_city(city_slug: city_slug, event: "maintenance.protocol.draft_saved", module_name: "protocol",
                rejection_path: "definition", protocol_key: definition["name"],
                version: definition["version"], changed_fields: [ "definition" ]) do |actor, correlation_id|
          Protocols::SaveDraft.call(definition: definition, by: actor, correlation_id: correlation_id)
        end
      end
    end
  end
end
