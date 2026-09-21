module Maintenance
  module Types
    class MutationType < BaseObject
      description "Escritas da API de manutenção"

      field :invite_maintainer, mutation: Mutations::InviteMaintainer
      field :deactivate_maintainer, mutation: Mutations::DeactivateMaintainer
      field :create_maintenance_token, mutation: Mutations::CreateMaintenanceToken
      field :revoke_maintenance_token, mutation: Mutations::RevokeMaintenanceToken
      field :save_protocol_draft, mutation: Mutations::SaveProtocolDraft
      field :submit_protocol_for_review, mutation: Mutations::SubmitProtocolForReview
      field :publish_protocol, mutation: Mutations::PublishProtocol
    end
  end
end
