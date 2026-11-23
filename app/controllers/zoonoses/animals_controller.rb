# /zoonoses/animals (módulo 35b, ADR 0054; contrato §2, §10, §16, Q2, Q26,
# Q31): o animal do centro de zoonoses, para team? (403 missing_role).
#   - POST /animals (Zoonoses::SaveAnimal) → 201 com o animal (sem tutor);
#   - PATCH /animals/:id com expected_version → o animal;
#   - GET /animals/:id → o detalhe com o tutor { id, display_name } e o
#     histórico (Q2); com tutor, a trilha `animal.viewed` (Q26);
#   - POST /animals/search `{ microchip? | registry_number? | tutor_patient_id?
#     | household_id?, before? }`: exatamente um critério (senão 422
#     invalid_request com o path do segundo; nenhum → path microchip).
#     Microchip ou registro → `{ items: [≤1] }`; tutor ou domicílio → `{ items,
#     next_before }`, 50 por página, mais recente primeiro, com o cursor no
#     corpo (`before`). Nunca por GET: o microchip não vai em URL nem em log.
# Toda rota recusa query (422 invalid_request, nada lido da URL). O número do
# microchip nunca sai (só has_microchip); a lista nunca traz o tutor.
module Zoonoses
  class AnimalsController < BaseController
    CRITERIA = %w[microchip registry_number tutor_patient_id household_id].freeze
    SEARCH_KEYS = (CRITERIA + %w[before]).freeze
    LIMIT = 50
    KEY_PATH_MAX = 64

    before_action :team!
    before_action { query_only! }

    def create
      result = SaveAnimal.call(params: body, by: Current.user)
      return render_failure(result) if result.failure?

      render json: Json.animal(result.payload.fetch(:animal)), status: :created
    end

    def update
      animal = find_animal
      return not_found unless animal

      result = SaveAnimal.call(params: body, by: Current.user, animal: animal)
      return render_failure(result) if result.failure?

      render json: Json.animal(result.payload.fetch(:animal))
    end

    def show
      animal = find_animal
      return not_found unless animal

      tutor = animal.tutor_patient
      Trail.animal_viewed!(user: Current.user, animal_id: animal.id) if tutor
      render json: Json.animal_detail(animal, tutor: tutor)
    end

    def search
      unknown = (body.keys - SEARCH_KEYS).first
      return render_refusal("invalid_request", path: unknown.to_s[0, KEY_PATH_MAX]) if unknown

      given = CRITERIA.select { |key| body.key?(key) }
      return render_refusal("invalid_request", path: given.second || CRITERIA.first) unless given.one?

      key = given.first
      value = body[key]
      case key
      when "microchip", "registry_number" then search_one(key, value)
      else search_page(key, value)
      end
    end

    private

    def find_animal = uuid?(params[:id]) ? Animal.find_by(id: params[:id]) : nil

    def search_one(key, value)
      return render_refusal("invalid_request", path: "before") if body.key?("before")

      animal =
        if key == "microchip"
          value.is_a?(String) && value.match?(Catalog::MICROCHIP) ? Animal.find_by(microchip: value) : :invalid
        else
          text = value.is_a?(String) ? value.strip : nil
          text && Catalog::REGISTRY_NUMBER.cover?(text.length) ? Animal.find_by("lower(registry_number) = lower(?)", text) : :invalid
        end
      return render_refusal("invalid_request", path: key) if animal == :invalid

      render json: { items: Json.animal_list([ animal ].compact) }
    end

    def search_page(key, value)
      return render_refusal("invalid_request", path: key) unless uuid?(value)

      position = CareLines::Cursor.decode(body["before"])
      rows, next_before = page(Animal.where(key => value.downcase), :created_at, limit: LIMIT, position: position)
      render json: { items: Json.animal_list(rows), next_before: next_before }
    rescue CareLines::Cursor::Invalid
      render_refusal("invalid_cursor")
    end
  end
end
