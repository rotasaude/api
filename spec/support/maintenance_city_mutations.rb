# Leitura compartilhada pelas guardas das mutations de cidade da API de
# manutenção (spec/architecture/maintenance_schema_spec.rb,
# spec/graphql/maintenance/analyzers_spec.rb,
# spec/requests/maintenance/protocol_mutations_spec.rb). Incluído explicitamente
# por quem usa, não em toda a suíte.
module MaintenanceCityMutationSpecHelpers
  # Campos de Mutation (nome publicado => campo) resolvidos por uma subclasse
  # de CityMutation — a lista que toda guarda de escrita em cidade confere.
  def city_mutation_fields
    Maintenance::Schema.mutation.fields.select { |_name, field| field.resolver < Maintenance::Mutations::CityMutation }
  end

  # Código sem linha de comentário: uma guarda satisfeita (ou disparada) por
  # comentário não serve.
  def strip_comments(source)
    source.lines.reject { |line| line.strip.start_with?("#") }.join
  end

  def code_only(path)
    strip_comments(File.read(path))
  end
end
