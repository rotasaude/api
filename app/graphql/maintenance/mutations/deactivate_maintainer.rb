module Maintenance
  module Mutations
    class DeactivateMaintainer < BaseMutation
      description "Desativa um mantenedor, encerrando sessões e tokens na hora"

      argument :id, ID, required: true

      field :ok, Boolean, null: false
      field :errors, [ Types::UserErrorType ], null: false

      def resolve(id:)
        audited(event: "maintenance.maintainer.deactivated", module_name: "maintainer", target_id: id) do
          target = Maintainer.find_by(id: id)
          raise Rejected.new("mantenedor não encontrado", path: "id") unless target
          raise Rejected.new("ninguém desativa a si mesmo", path: "id") if target.id == credential.maintainer.id

          begin
            target.deactivate!
          rescue Maintainer::LastActive
            raise Rejected.new("é o último mantenedor ativo", path: "id")
          end
        end
      end
    end
  end
end
