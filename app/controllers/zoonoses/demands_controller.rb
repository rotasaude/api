# /zoonoses/demands (módulo 35b, ADR 0054; contrato §4, §10, §16; Q13, Q26,
# Q33): a fila do centro de zoonoses e o andamento da demanda, para team?
# (403 missing_role).
#   - GET /demands?state=&before=&limit= → `{ items, next_before }`, mais
#     recente primeiro (50 por página, até 100), com `{ id, subtype, state,
#     due_on, color, version, forwarding_state }` (Zoonoses::Json.demand). Sem
#     o extrato, o place_address, a identidade, o contato, o protocolo nem os
#     anexos (Q13);
#   - GET /demands/:id → o detalhe, com o extrato e o place_address da
#     manifestação, e a trilha `zoonoses_demand.viewed` { zoonoses_demand_id,
#     user_id } (Q26);
#   - POST /demands/:id/{schedule,inspect,close,decline,extend}
#     (Zoonoses::AdvanceDemand, com expected_version) → a linha com as datas e
#     o desfecho, ainda sem o extrato nem o endereço.
# O prazo e a cor são os do encaminhamento (Ombudsman::Deadlines, "hoje" da
# cidade). A escrita e o detalhe recusam query (422 invalid_request); a lista
# recusa chave fora dos filtros.
# Q35: leitura e escrita pedem também a ouvidoria utilizável (o gate do 33,
# OmbudsmanGate, lido aqui, fora da transação da cidade): desligada → 403
# `{ error: feature_disabled, feature: ombudsman }`, o mesmo corpo do 33. A
# demanda fica gravada e volta quando a ouvidoria é religada.
module Zoonoses
  class DemandsController < BaseController
    include ::OmbudsmanGate

    FILTERS = %i[state before limit].freeze

    before_action :require_ombudsman!
    before_action :team!
    before_action(only: %i[show advance]) { query_only! }

    def index
      return unless query_only!(*FILTERS)

      state = request.query_parameters["state"]
      return render_refusal("invalid_request", path: "state") unless state.nil? || Catalog::DEMAND_STATES.include?(state)

      limit = page_limit
      return unless limit

      scope = ZoonosesDemand.preload(:ombudsman_forwarding)
      scope = scope.where(state: state) if state
      position = CareLines::Cursor.decode(request.query_parameters["before"])
      rows, next_before = page(scope, :created_at, limit: limit, position: position)
      settings = OmbudsmanSetting.current
      today = Time.zone.today
      render json: { items: rows.map { Json.demand(_1, _1.ombudsman_forwarding, settings: settings, today: today) },
                     next_before: next_before }
    rescue CareLines::Cursor::Invalid
      render_refusal("invalid_cursor")
    end

    def show
      demand = find_demand
      return not_found unless demand

      forwarding = demand.ombudsman_forwarding
      Trail.demand_viewed!(user: Current.user, demand_id: demand.id)
      render json: Json.demand_detail(demand, forwarding, forwarding.ombudsman_manifestation, settings: OmbudsmanSetting.current,
                                                                                               today: Time.zone.today)
    end

    def advance
      demand = find_demand
      return not_found unless demand

      result = AdvanceDemand.call(demand: demand, action: params[:step], params: body, by: Current.user)
      return render_failure(result) if result.failure?

      render json: Json.demand_record(result.payload.fetch(:demand), result.payload.fetch(:forwarding),
                                      settings: OmbudsmanSetting.current, today: Time.zone.today)
    end

    private

    def find_demand = uuid?(params[:id]) ? ZoonosesDemand.find_by(id: params[:id]) : nil
  end
end
