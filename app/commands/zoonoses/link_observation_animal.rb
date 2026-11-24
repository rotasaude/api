# Liga o animal cadastrado à observação do animal agressor (módulo 35b, ADR
# 0054; contrato §5: "o animal pode ser cadastrado e ligado a qualquer
# momento"; decisão do controlador: em qualquer estado, open ou closed, uma
# vez — o trigger rota_bite_observation_guard aceita animal_id de NULL a
# valor também na fechada). POST /zoonoses/observations/:id/link_animal,
# para team? (senão missing_role). Corpo: `animal_id` (UUID de um animal da
# mesma espécie da observação, senão invalid_request path animal_id) e o
# obrigatório `expected_version` (ausente → expected_version_required;
# diferente → 409 observation_changed).
#
# Travas na ordem das escritas do canil (EnterShelter, AnimalDeath): o animal
# FOR UPDATE antes da observação; a ordem inversa formaria um ciclo com a
# entrada observation. Já ligada a outro animal → 409 observation_changed; ao
# mesmo animal → nada muda (Result.ok). O animal não muda (nenhum status nem
# versão). Sem evento: o catálogo do §16 não tem um para a ligação, e o
# histórico do animal (Zoonoses::Json) a lê da própria observação.
module Zoonoses
  module LinkObservationAnimal
    KEYS = %w[animal_id expected_version].freeze
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    KEY_PATH_MAX = 64

    module_function

    # -> Result.ok(observation:) | fail(:invalid_request, details: { path: }) |
    #    fail(:expected_version_required, details: { path: "expected_version" }) | fail(:missing_role | :observation_changed)
    def call(observation:, params:, by:)
      return Result.fail(:missing_role) unless Access.team?(by)

      attrs = parse(params.to_h.stringify_keys)
      return attrs if attrs.is_a?(Result)

      BiteObservation.transaction(requires_new: true) { link(observation.id, attrs) }
    end

    def link(id, attrs)
      animal = Animal.lock.find_by(id: attrs[:animal_id])
      return invalid("animal_id") unless animal

      row = BiteObservation.lock.find(id)
      return Result.fail(:observation_changed) unless row.version == attrs[:expected_version]
      return Result.ok(observation: row) if row.animal_id == animal.id
      return Result.fail(:observation_changed) unless row.animal_id.nil?
      return invalid("animal_id") unless animal.species == row.species
      # O status do animal não é conferido de propósito: ele pode ter morrido durante a observação.

      row.update!(animal_id: animal.id, version: row.version + 1)
      Result.ok(observation: row)
    end

    # Forma do corpo. -> { atributo => valor } | Result de recusa (só a primeira).
    def parse(params)
      unknown = params.keys.find { |key| !KEYS.include?(key) }
      return invalid(unknown.to_s[0, KEY_PATH_MAX]) if unknown
      return invalid("animal_id") unless params["animal_id"].is_a?(String) && params["animal_id"].match?(UUID)
      return Result.fail(:expected_version_required, details: { path: "expected_version" }) unless params.key?("expected_version")

      version = params["expected_version"]
      return invalid("expected_version") unless version.is_a?(Integer) && version.positive?

      { animal_id: params["animal_id"].downcase, expected_version: version }
    end

    def invalid(path) = Result.fail(:invalid_request, details: { path: path })

    private_class_method :link, :parse, :invalid
  end
end
