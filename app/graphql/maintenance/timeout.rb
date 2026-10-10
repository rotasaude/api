module Maintenance
  # Limite de tempo do schema (spec §8: 10 s) com uma única exceção: as
  # importações do catálogo (CATMAT real ~25 s) e das listas da Anvisa são
  # síncronas e ganham 300 s. A exceção vale só quando a operação é feita
  # APENAS dessas mutations (campos de topo, sem fragmento), para que ninguém
  # pendure outro campo nelas e herde o limite longo.
  class Timeout < GraphQL::Schema::Timeout
    IMPORT_MUTATIONS = %w[importMedicationCatalog importAnvisaLists].freeze
    IMPORT_MAX_SECONDS = 300

    def max_seconds(query)
      import_only?(query&.selected_operation) ? IMPORT_MAX_SECONDS : super
    end

    private

    def import_only?(operation)
      return false unless operation&.operation_type == "mutation"

      fields = operation.selections
      fields.any? && fields.all? { |node| node.is_a?(GraphQL::Language::Nodes::Field) && IMPORT_MUTATIONS.include?(node.name) }
    end
  end
end
