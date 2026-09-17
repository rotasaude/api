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

          token.revoke!
        end
      end
    end
  end
end
