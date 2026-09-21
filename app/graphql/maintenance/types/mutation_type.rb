module Maintenance
  module Types
    class MutationType < BaseObject
      description "Escritas da API de manutenção"

      field :invite_maintainer, mutation: Mutations::InviteMaintainer
      field :deactivate_maintainer, mutation: Mutations::DeactivateMaintainer
      field :create_maintenance_token, mutation: Mutations::CreateMaintenanceToken
      field :revoke_maintenance_token, mutation: Mutations::RevokeMaintenanceToken
      field :save_protocol_draft, mutation: Mutations::SaveProtocolDraft
    end
  end
end
