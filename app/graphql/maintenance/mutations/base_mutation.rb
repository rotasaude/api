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

      # Step-up de TOTP (spec §7). A sessão já está verificada, mas estas
      # escritas emitem uma credencial de longa vida ou refazem uma conta, e o
      # código é CONSUMIDO (I3) — o que verificou a sessão não vale aqui.
      #
      # C2 (fix round 2): a falha conta para o MESMO bloqueio de conta do
      # challenge do navegador. Sem isso, uma sessão sequestrada tinha palpites
      # ilimitados contra o TOTP — e a tolerância de relógio deixa ~3 códigos
      # válidos ao mesmo tempo — até emitir um token de 90 dias, que sobrevive
      # a toda a limitação de tempo da sessão de onde saiu. E conta bloqueada
      # não passa por aqui, como não passa no login.
      def step_up!(code, path: "code")
        maintainer = credential.maintainer
        raise Rejected.new("conta bloqueada", path: path) if maintainer.locked?
        return if maintainer.consume_totp!(code)

        register_step_up_failure(maintainer)
        raise Rejected.new("código inválido", path: path)
      end

      # Os MESMOS nomes de evento do challenge do navegador, de propósito: é o
      # mesmo contador e o mesmo bloqueio, e quem investiga uma conta sob
      # ataque precisa ver as duas superfícies na mesma sequência.
      def register_step_up_failure(maintainer)
        maintainer.register_failure!
        locked = maintainer.reload.locked?

        MaintenanceAudit.record(locked ? "maintenance.session.locked" : "maintenance.session.failed",
                                outcome: "rejected", module_name: "session",
                                maintainer_id: maintainer.id, credential: { "kind" => "totp" })
      end

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
