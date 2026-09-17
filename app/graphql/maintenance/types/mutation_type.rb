module Maintenance
  module Types
    class MutationType < BaseObject
      description "Escritas da API de manutenção"

      field :invite_maintainer, mutation: Mutations::InviteMaintainer
      field :deactivate_maintainer, mutation: Mutations::DeactivateMaintainer
    end
  end
end
