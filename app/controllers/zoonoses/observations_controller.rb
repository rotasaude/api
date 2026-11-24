# /zoonoses/observations (módulo 35b, ADR 0054; contrato §5, §10, §16;
# decisão 32, Q12, Q16, Q26): a fila de observações do animal agressor, para
# team? (403 missing_role).
#   - GET /observations?state=&before=&limit= → `{ items, next_before }`, mais
#     recente primeiro (50 por página, até 100), com `{ id, species,
#     condition, exposure_on, ends_on, days_left, state, place, version,
#     animal_id }` (Zoonoses::Json.bite_observation);
#   - GET /observations/:id → o mesmo mais o desfecho;
#   - GET /observations/:id/contact → o nome e o telefone do tutor e o
#     endereço do animal, da ficha (Zoonoses::ObservationContact), com a
#     trilha bite_observation.contact_viewed e Cache-Control: no-store; sem
#     step-up a mais (Q12);
#   - POST /observations/:id/close (Zoonoses::CloseObservation) e
#     /observations/:id/link_animal (Zoonoses::LinkObservationAnimal), com
#     expected_version → o detalhe.
# Nunca o paciente, a idade, a unidade nem a disease_notification_id; o
# contato só na rota própria. A condição vem da ficha do 25 (lida aqui, nunca
# devolvida inteira). Escrita, detalhe e contato recusam query (422
# invalid_request); a lista recusa chave fora dos filtros.
module Zoonoses
  class ObservationsController < BaseController
    FILTERS = %i[state before limit].freeze

    before_action :team!
    before_action(only: %i[show contact close_observation link_animal]) { query_only! }

    def index
      return unless query_only!(*FILTERS)

      state = request.query_parameters["state"]
      return render_refusal("invalid_request", path: "state") unless state.nil? || Catalog::OBSERVATION_STATES.include?(state)

      limit = page_limit
      return unless limit

      scope = BiteObservation.preload(:disease_notification)
      scope = scope.where(state: state) if state
      position = CareLines::Cursor.decode(request.query_parameters["before"])
      rows, next_before = page(scope, :created_at, limit: limit, position: position)
      today = Time.zone.today
      render json: { items: rows.map { Json.bite_observation(_1, condition: condition(_1), today: today) }, next_before: next_before }
    rescue CareLines::Cursor::Invalid
      render_refusal("invalid_cursor")
    end

    def show
      observation = find_observation
      return not_found unless observation

      render_detail(observation)
    end

    def contact
      observation = find_observation
      return not_found unless observation

      result = ObservationContact.call(observation: observation, by: Current.user)
      return render_failure(result) if result.failure?

      response.headers["Cache-Control"] = "no-store"
      render json: result.payload.fetch(:contact)
    end

    def close_observation
      observation = find_observation
      return not_found unless observation

      result = CloseObservation.call(observation: observation, params: body, by: Current.user)
      return render_failure(result) if result.failure?

      render_detail(result.payload.fetch(:observation))
    end

    def link_animal
      observation = find_observation
      return not_found unless observation

      result = LinkObservationAnimal.call(observation: observation, params: body, by: Current.user)
      return render_failure(result) if result.failure?

      render_detail(result.payload.fetch(:observation))
    end

    private

    def find_observation = uuid?(params[:id]) ? BiteObservation.find_by(id: params[:id]) : nil

    def render_detail(observation)
      render json: Json.bite_observation_detail(observation, condition: condition(observation), today: Time.zone.today)
    end

    # A condição do animal, do bloco da ficha do 25 (ausente → nil).
    def condition(observation)
      form = observation.disease_notification.form
      form.is_a?(Hash) ? form["animal_condition"] : nil
    end
  end
end
