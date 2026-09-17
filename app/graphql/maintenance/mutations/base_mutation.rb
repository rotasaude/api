# Base das mutations da API de manutenção.
#
# O par tentativa/resultado da auditoria (spec §9) mora AQUI, não em cada
# mutation: a escrita acontece no banco de plataforma e a auditoria também, mas
# uma mutation nova não pode depender de alguém lembrar de auditá-la. A tentativa
# é gravada ANTES de executar, e se essa gravação falhar o bloco não roda —
# nenhuma alteração sem registro.
module Maintenance
  module Mutations
    # GraphQL::Schema::Mutation, não RelayClassicMutation: os argumentos ficam no
    # próprio campo (`inviteMaintainer(emailAddress: ...)`), sem o invólucro
    # `input:` nem o `clientMutationId` do estilo Relay, que este frontend não usa.
    class BaseMutation < GraphQL::Schema::Mutation
      class Rejected < StandardError
        attr_reader :path

        def initialize(message, path: nil)
          super(message)
          @path = path
        end
      end

      private

      def credential = context.fetch(:credential)

      def audited(event:, module_name:, **fields)
        correlation_id = MaintenanceAudit.record(event, outcome: "attempted", module_name: module_name,
                                                 maintainer_id: credential.maintainer.id,
                                                 credential: credential.audit_payload, **fields)

        result = yield
        record_outcome(event, "ok", module_name, correlation_id, fields)
        { ok: true, errors: [] }
      rescue Rejected => e
        record_outcome(event, "rejected", module_name, correlation_id, fields)
        { ok: false, errors: [ { path: e.path, message: e.message } ] }
      rescue StandardError
        record_outcome(event, "error", module_name, correlation_id, fields) if correlation_id
        raise
      end

      def record_outcome(event, outcome, module_name, correlation_id, fields)
        MaintenanceAudit.record(event, outcome: outcome, module_name: module_name,
                                maintainer_id: credential.maintainer.id,
                                credential: credential.audit_payload,
                                correlation_id: correlation_id, **fields)
      end
    end
  end
end
