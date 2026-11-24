# A área do inquérito de leishmaniose (módulo 35b, ADR 0054; contrato §6,
# Q8, Q18, Q21, Q28): lê os quarteirões e anéis do 35a (city_blocks,
# VectorControl::Rings) mesmo sem o vector_control (Q8), e os domicílios e
# cães deles. Os domicílios do quarteirão são os ativos com perfil
# (household_vector_profiles) nele.
#
#   - `household_ids(block_ids)`: os domicílios dos quarteirões (Q21; o feed
#     do app, Task 17, recorta pelo escopo do agente);
#   - `suggested_population(block_ids, parameters:)`: a sugestão de
#     dog_population (Q18, Zoonoses::LeishSample.suggested_population com os
#     cães active dos domicílios);
#   - `suggestion(...)` (Q28): os quarteirões, a população sugerida, o
#     target_dogs e o below_focus_min. No foco, os anéis em volta do central,
#     a partir de `rings` (padrão 1), ampliados um a um até a população chegar
#     a leish_focus_min_dogs, no máximo MAX_FOCUS_RINGS (adendo do
#     coordenador); nos outros tipos, os quarteirões ativos do bairro.
module Zoonoses
  module SurveyArea
    DEFAULT_FOCUS_RINGS = 1
    MAX_FOCUS_RINGS = 5

    module_function

    def household_ids(block_ids)
      households(block_ids).order(:household_id).pluck(:household_id)
    end

    def includes_household?(block_ids, household_id) = households(block_ids).exists?(household_id: household_id)

    def active_dogs(block_ids)
      Animal.active.where(species: "dog", household_id: households(block_ids).select(:household_id)).count
    end

    def suggested_population(block_ids, parameters:)
      LeishSample.suggested_population(active_dogs: active_dogs(block_ids), blocks_count: block_ids.size, parameters: parameters)
    end

    # -> { city_block_ids:, dog_population_suggested:, target_dogs:, below_focus_min: }
    def suggestion(kind:, neighborhood_id:, parameters:, center_block_id: nil, rings: nil)
      if kind == "focus"
        block_ids, population = focus_area(center_block_id, rings || DEFAULT_FOCUS_RINGS, parameters)
      else
        block_ids = CityBlock.active_blocks.where(neighborhood_id: neighborhood_id).natural_number_order.pluck(:id)
        population = suggested_population(block_ids, parameters: parameters)
      end
      { city_block_ids: block_ids, dog_population_suggested: population,
        target_dogs: LeishSample.target(kind: kind, dog_population: population, parameters: parameters),
        below_focus_min: LeishSample.below_focus_min?(kind: kind, dog_population: population, parameters: parameters) }
    end

    # Amplia o anel até o mínimo do foco ou MAX_FOCUS_RINGS; para antes se o
    # anel seguinte não acrescenta quarteirão. -> [block_ids, população]
    def focus_area(center_block_id, ring, parameters)
      minimum = parameters.values.fetch("leish_focus_min_dogs")
      loop do
        block_ids = VectorControl::Rings.around([ center_block_id ], rings: ring)
        population = suggested_population(block_ids, parameters: parameters)
        return [ block_ids, population ] if population >= minimum || ring >= MAX_FOCUS_RINGS
        return [ block_ids, population ] if VectorControl::Rings.around([ center_block_id ], rings: ring + 1).size == block_ids.size

        ring += 1
      end
    end

    def households(block_ids)
      HouseholdVectorProfile.joins(:household).where(city_block_id: block_ids, households: { status: "active" })
    end
    private_class_method :focus_area, :households
  end
end
