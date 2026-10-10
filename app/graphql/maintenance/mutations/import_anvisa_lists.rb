module Maintenance
  module Mutations
    # ADR 0033 (contrato §8): importa as listas versionadas em config/medications/anvisa.
    class ImportAnvisaLists < BaseMutation
      description "Importa as listas da Anvisa (antimicrobianos e controlados) e remarca o catálogo."

      field :ok, Boolean, null: false
      field :errors, [ Types::UserErrorType ], null: false
      field :antimicrobials, Integer, null: true
      field :controlled, Integer, null: true

      def resolve
        outcome = nil
        result = audited(event: "maintenance.anvisa_lists.imported", module_name: "medications") do
          outcome = Medications::AnvisaImport.call(by: "maintenance:#{credential.maintainer.id}",
                                                   dir: Medications::AnvisaImport::DIR)
          raise Rejected.new(outcome.reason.to_s, path: "lists") if outcome.failure?
        end
        result.merge(antimicrobials: outcome&.ok? ? outcome.payload[:antimicrobials] : nil,
                     controlled: outcome&.ok? ? outcome.payload[:controlled] : nil)
      end
    end
  end
end
