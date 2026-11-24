# Tamanho do inquérito de leishmaniose visceral canina (módulo 35b, ADR 0054;
# contrato §6, Q18, Q32). Regras puras: recebem a população e o
# Zoonoses::Parameters::Snapshot já lidos.
#
#   - `target`:
#       - sample: a amostra da primeira linha da `leish_sample_table` (a de 2%,
#         Q18) com `population` ≥ dog_population; acima da última linha, a
#         amostra da última. Abaixo do `min_population` da primeira linha (Q32,
#         lido da tabela, nunca do código), todos os cães (censo);
#       - census: dog_population;
#       - focus: dog_population (Q32 "em qualquer caso" prevalece sobre o
#         max(leish_focus_min_dogs, …) do §6: decisão do coordenador); o aviso
#         sai por `below_focus_min?`.
#     Em todo tipo, target ≤ dog_population.
#   - `below_focus_min?`: foco com menos cães que `leish_focus_min_dogs` (a
#     tela avisa).
#   - `suggested_population` (Q18): os cães ativos cadastrados nos
#     quarteirões; com zero, quarteirões × dogs_per_block.
module Zoonoses
  module LeishSample
    module_function

    def target(kind:, dog_population:, parameters:)
      raise ArgumentError, "kind: #{kind}" unless Catalog::SURVEY_KINDS.include?(kind)

      planned = kind == "sample" ? sample(dog_population, parameters.values.fetch("leish_sample_table")) : dog_population
      [ planned, dog_population ].min
    end

    def below_focus_min?(kind:, dog_population:, parameters:)
      kind == "focus" && dog_population < parameters.values.fetch("leish_focus_min_dogs")
    end

    def suggested_population(active_dogs:, blocks_count:, parameters:)
      return active_dogs if active_dogs.positive?

      blocks_count * parameters.values.fetch("dogs_per_block")
    end

    def sample(dog_population, table)
      floor = table.first["min_population"]
      return dog_population if floor && dog_population < floor

      (table.find { |row| row.fetch("population") >= dog_population } || table.last).fetch("sample")
    end
    private_class_method :sample
  end
end
