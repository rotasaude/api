# /zoonoses/shelter_stays (módulo 35b, ADR 0054; contrato §7, §10, §16): o
# canil e o gatil, para team? (403 missing_role).
#   - POST /shelter_stays (Zoonoses::EnterShelter) → 201 com a estada e o
#     `animal` (Zoonoses::Json.animal: sem tutor, só has_tutor);
#   - POST /shelter_stays/:id/exit (Zoonoses::ExitShelter, com
#     expected_version) → a estada;
#   - GET /shelter_stays?open=1&health_unit_id=&before=&limit= → `{ items,
#     next_before, occupancy }`, mais recente primeiro (50 por página, até
#     100); `occupancy` é a lotação: as estadas abertas por unidade (com o
#     filtro de unidade), sem limite no sistema.
# Nunca o tutor nem o adotante na lista ou na resposta. A escrita recusa query
# (422 invalid_request); a lista recusa chave fora dos filtros.
module Zoonoses
  class ShelterStaysController < BaseController
    FILTERS = %i[open health_unit_id before limit].freeze

    before_action :team!
    before_action(only: %i[create exit_stay]) { query_only! }

    def index
      return unless query_only!(*FILTERS)

      open = request.query_parameters["open"]
      return render_refusal("invalid_request", path: "open") unless open.nil? || open == "1"

      unit_id = query_uuid("health_unit_id")
      return if performed?

      limit = page_limit
      return unless limit

      scope = ShelterStay.all
      scope = scope.where(health_unit_id: unit_id) if unit_id
      position = CareLines::Cursor.decode(request.query_parameters["before"])
      rows, next_before = page(open ? scope.open_stays : scope, :created_at, limit: limit, position: position)
      species = Animal.where(id: rows.map(&:animal_id)).pluck(:id, :species).to_h
      render json: { items: rows.map { Json.shelter_stay(_1, species: species.fetch(_1.animal_id)) }, next_before: next_before,
                     occupancy: occupancy(scope) }
    rescue CareLines::Cursor::Invalid
      render_refusal("invalid_cursor")
    end

    def create
      result = EnterShelter.call(params: body, by: Current.user)
      return render_failure(result) if result.failure?

      animal = result.payload.fetch(:animal)
      render json: Json.shelter_stay(result.payload.fetch(:stay), species: animal.species).merge(animal: Json.animal(animal)),
             status: :created
    end

    def exit_stay
      stay = uuid?(params[:id]) ? ShelterStay.find_by(id: params[:id]) : nil
      return not_found unless stay

      result = ExitShelter.call(stay: stay, params: body, by: Current.user)
      return render_failure(result) if result.failure?

      render json: Json.shelter_stay(result.payload.fetch(:stay))
    end

    private

    def occupancy(scope)
      scope.open_stays.group(:health_unit_id).count.map { |unit_id, count| { health_unit_id: unit_id, open_stays: count } }
    end
  end
end
