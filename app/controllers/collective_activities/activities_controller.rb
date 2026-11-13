# /collective_activities (contrato §2, §4, §5, §7, §13; Q14, Q15, Q17, Q21,
# Q53, Q54; plano, Task 15, Desvio 11): a atividade coletiva na rota da equipe.
#   POST /collective_activities        Tabela 5: o corpo plano (Q15) vai ao
#                                      CollectiveActivities::Record → 201
#                                      <collective_activity>; o mesmo client_uuid
#                                      já gravado pelo usuário → 200 com a gravada
#   GET  /collective_activities?team_id=&from=&to=&activity_type[]=&state[]=&before=&limit=
#                                      a equipe: { items (sem participantes nem
#                                      temas), next_before }, sem trilha; `mistaken`
#                                      fora por padrão (state[]=mistaken a mostra);
#                                      ordem held_on DESC, id DESC e o cursor nela
#   GET  /collective_activities/:id    a equipe: <collective_activity> (trilha)
#   POST /collective_activities/:id/mark_mistaken   quem registrou:
#                                      { expected_state, reason } → 200
# Resposta com atividade completa grava uma trilha clinical_record.viewed (só
# ids); a dos candidatos do 409 duplicate_suspected é do Record (depois da
# transação). Atividade de outro escopo por id → 404 (antes de olhar o corpo);
# equipe alheia na lista → 403 out_of_scope. Pessoa e texto nunca na query.
module CollectiveActivities
  class ActivitiesController < BaseController
    LIST_KEYS = %i[team_id from to activity_type state before limit].freeze
    MISTAKEN_KEYS = %w[expected_state reason].freeze
    TYPES = Catalog::TYPES.map(&:to_s).freeze
    CURSOR = /\A(\d{4}-\d{2}-\d{2})\|(\h{8}-\h{4}-\h{4}-\h{4}-\h{12})\z/

    def create
      return unless query_only!

      result = Record.call(params: body, by: Current.user)
      return render_failure(result) if result.failure?

      show_activity(result.payload[:activity].id, status: result.payload[:replayed] ? :ok : :created)
    end

    def show
      return unless query_only!

      activity = uuid?(params[:id]) && CollectiveActivity.includes(:team).find_by(id: params[:id])
      return render_refusal("not_found") unless activity && Access.reads?(Current.user, activity.team)

      show_activity(activity.id)
    end

    def mark_mistaken
      return unless query_only!

      activity = uuid?(params[:id]) && CollectiveActivity.find_by(id: params[:id], recorded_by_user_id: Current.user.id)
      return render_refusal("not_found") unless activity

      unknown = (body.keys - MISTAKEN_KEYS).first
      return render_refusal("invalid_request", path: unknown[0, 64]) if unknown

      result = MarkMistaken.call(activity, by: Current.user, expected_state: body_param("expected_state"), reason: body_param("reason"))
      return render_failure(result) if result.failure?

      show_activity(activity.id)
    end

    def index
      return unless query_only!(*LIST_KEYS)

      scope = list_scope
      return unless scope

      limit = page_limit
      return unless limit

      position = activity_cursor
      return if performed?

      scope = scope.where("(collective_activities.held_on, collective_activities.id) < (?, ?::uuid)", *position) if position
      rows = scope.order(held_on: :desc, id: :desc).limit(limit + 1).to_a
      page = rows.first(limit)
      render json: { items: Json.activities(page, viewer: Current.user, full: false),
                     next_before: rows.size > limit ? encode_cursor(page.last) : nil }
    end

    private

    # A atividade completa, relida, com a trilha (a atividade e os pacientes).
    def show_activity(id, status: :ok)
      activity = CollectiveActivity.find(id)
      json = Json.activities([ activity ], viewer: Current.user).sole
      Trail.activities_viewed!(user: Current.user, collective_activity_ids: [ activity.id ],
                               patient_ids: activity.participants.map(&:patient_id))
      render json: json, status: status
    end

    # As atividades da equipe em que quem lê lê (Tabela 5, enfermeiro,
    # médico), com os filtros. Sem id válido → 422 (path team_id); equipe
    # alheia ou desconhecida → 403 out_of_scope. nil = já respondeu.
    def list_scope
      id = request.query_parameters["team_id"]
      unless uuid?(id)
        render_refusal("invalid_request", path: "team_id")
        return nil
      end

      team = HealthTeam.find_by(id: id)
      unless team && Access.reads?(Current.user, team)
        render_refusal("out_of_scope")
        return nil
      end

      from = query_date("from")
      to = query_date("to") unless performed?
      types = list_filter("activity_type", TYPES) unless performed?
      states = list_filter("state", %w[recorded mistaken]) unless performed?
      return nil if performed?

      scope = CollectiveActivity.where(team_id: team.id)
      scope = scope.where(held_on: from..) if from
      scope = scope.where(held_on: ..to) if to
      scope = scope.where(activity_type: types.map(&:to_i)) if types
      states ||= %w[recorded]
      scope = scope.where.not(mistaken_at: nil) unless states.include?("recorded")
      scope = scope.where(mistaken_at: nil) unless states.include?("mistaken")
      scope
    end

    # Cursor opaco (Q52-like): a posição na ordem held_on DESC, id DESC —
    # "AAAA-MM-DD|id" em base64 url-safe.
    def encode_cursor(activity) = Base64.urlsafe_encode64("#{activity.held_on.iso8601}|#{activity.id}", padding: false)

    # [dia, id] | nil (sem before); inválido → 422 invalid_cursor.
    def activity_cursor
      raw = params[:before]
      return nil if raw.nil? || raw == ""

      match = raw.is_a?(String) && Base64.urlsafe_decode64(raw).match(CURSOR)
      raise ArgumentError, "cursor" unless match

      [ Date.iso8601(match[1]), match[2].downcase ]
    rescue ArgumentError
      render_refusal("invalid_cursor")
      nil
    end
  end
end
