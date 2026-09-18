module Maintenance
  module Mutations
    class RevokeMaintenanceToken < BaseMutation
      description "Revoga um token de serviço na hora"

      argument :id, ID, required: true

      field :ok, Boolean, null: false
      field :errors, [ Types::UserErrorType ], null: false

      def resolve(id:)
        audited(event: "maintenance.token.revoked", module_name: "token", target_id: id) do
          token = MaintenanceToken.find_by(id: id)
          raise Rejected.new("token não encontrado", path: "id") unless token

          # M3 (fix round 2): revogar de novo era `ok`, e re-carimbava
          # `revoked_at` — a trilha passava a dizer que o token foi revogado
          # agora, apagando o momento em que de fato foi. Erro de usuário, não
          # idempotência silenciosa: quem chamou precisa saber que nada mudou,
          # e o instante da revogação é prova.
          raise Rejected.new("token já revogado", path: "id") if token.revoked_at

          token.revoke!
        end
      end
    end
  end
end
