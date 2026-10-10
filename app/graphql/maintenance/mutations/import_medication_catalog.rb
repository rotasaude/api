module Maintenance
  module Mutations
    # ADR 0033 (contrato §8): importa o CATMAT 6505 da API aberta (síncrono; a
    # API leva segundos). Escreve só na plataforma; auditado pela base.
    class ImportMedicationCatalog < BaseMutation
      description "Importa o catálogo de medicamentos (CATMAT classe 6505) e mostra a diferença."

      field :ok, Boolean, null: false
      field :errors, [ Types::UserErrorType ], null: false
      field :release_id, ID, null: true
      field :added, Integer, null: true
      field :changed, Integer, null: true
      field :removed, Integer, null: true

      def resolve
        outcome = nil
        result = audited(event: "maintenance.medication_catalog.imported", module_name: "medications") do
          outcome = Medications::CatalogImport.call(by: "maintenance:#{credential.maintainer.id}")
          raise Rejected.new(outcome.reason.to_s, path: "catalog") if outcome.failure?
        end
        return result.merge(release_id: nil, added: nil, changed: nil, removed: nil) unless outcome&.ok?

        result.merge(release_id: outcome.payload[:release].id, **outcome.payload.slice(:added, :changed, :removed))
      end
    end
  end
end
