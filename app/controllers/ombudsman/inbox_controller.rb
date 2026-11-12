# Ponto de resposta (ADR 0051; contrato §6; §16 Q8, Q9, Q23, Q33, Q34, Q48).
# Só quem tem o papel ombudsman_responder (senão 403 missing_role); vê e age
# só nos encaminhamentos dos destinos em que é respondente ativo — de outro
# destino → 404.
#   GET  /ombudsman/inbox?state[]&before → { items: [<inbox_item>], next_before }:
#     `state[]` repetido em FORWARDING_STATES (escalar ou fora → 422 path
#     state); created_at DESC, id DESC, páginas de PAGE, cursor `before`
#     (cursor ruim → 422 invalid_cursor). Nunca o protocolo, a identidade, o
#     texto original, o assunto nem os anexos da manifestação.
#   POST /ombudsman/inbox/:id/reply   { expected_state, body }
#   POST /ombudsman/inbox/:id/decline { expected_state, reason }
#   POST /ombudsman/inbox/:id/extend  { expected_state, reason }
#     `expected_state` do encaminhamento (409 forwarding_changed); sucesso →
#     200 com o item atualizado do inbox, nunca o detalhe (Q48). A ação do
#     extend é `extend_forwarding`: `extend` é método de Object.
module Ombudsman
  class InboxController < BaseController
    PAGE = 50
    KEYS = {
      "reply" => %w[expected_state body], "decline" => %w[expected_state reason], "extend_forwarding" => %w[expected_state reason]
    }.freeze

    before_action :require_responder!
    before_action -> { body_keys!(KEYS.fetch(action_name)) }, except: :index
    before_action :uuid_id!, except: :index

    def index
      return unless query_only!("state", "before")

      query = request.query_parameters
      scope = Forwardings.inbox_scope(Current.user)
      if query.key?("state")
        states = query["state"]
        valid = states.is_a?(Array) && states.any? && states.all? { |s| s.is_a?(String) && Catalog::FORWARDING_STATES.include?(s) }
        return render_refusal("state") unless valid

        scope = scope.where(state: states)
      end
      if query.key?("before")
        at, id = CareRegulation::Cursor.decode_page(query["before"])
        scope = scope.where("(ombudsman_forwardings.created_at, ombudsman_forwardings.id) < (?, ?)", at, id)
      end
      rows = scope.includes(:department, :health_unit).order(created_at: :desc, id: :desc).limit(PAGE + 1).to_a
      page = rows.first(PAGE)
      settings = OmbudsmanSetting.current
      today = Time.zone.today
      render json: { items: page.map { |row| Json.inbox_item(row, settings, today) },
                     next_before: rows.size > PAGE ? CareRegulation::Cursor.encode_page(page.last.created_at, page.last.id) : nil }
    rescue CareRegulation::Cursor::Invalid
      render_refusal("before", "invalid_cursor")
    end

    def reply
      respond ReplyForwarding.call(forwarding_id: params[:id], expected_state: body_param("expected_state"), body: body_param("body"),
                                   by: Current.user)
    end

    def decline
      respond DeclineForwarding.call(forwarding_id: params[:id], expected_state: body_param("expected_state"),
                                     reason: body_param("reason"), by: Current.user)
    end

    def extend_forwarding
      respond ExtendForwarding.call(forwarding_id: params[:id], expected_state: body_param("expected_state"),
                                    reason: body_param("reason"), by: Current.user)
    end

    private

    def require_responder!
      return true if Access.responder?(Current.user)

      forbid
      false
    end

    def respond(result)
      return render_failure(result) if result.failure?

      forwarding = OmbudsmanForwarding.includes(:department, :health_unit).find(params[:id])
      render json: Json.inbox_item(forwarding, OmbudsmanSetting.current, Time.zone.today)
    end
  end
end
