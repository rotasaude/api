# /home_visits/days* (contrato §2, §6, §13; Q5, Q14, Q16, Q50; plano, Task 12):
# as folhas do dia na rota da equipe.
#   GET  days/today?team_id=   quem registra (ACS, Tabela 7): a sua folha aberta
#                              de hoje com as visitas (sem note), ou null;
#                              trilha só quando há visita com pessoa
#   GET  days?team_id=&professional_id=&from=&to=&state[]=&before=&limit=
#                              o dono (as suas) e o enfermeiro/médico (a
#                              equipe): { items, next_before }, sem pessoa e
#                              sem trilha, sem consulta por folha (Json.days);
#                              ordem day, sequence, id DESC e cursor nela (Q52)
#   GET  days/:id              o dono e o enfermeiro/médico da equipe: a folha
#                              com as visitas (sem note), com trilha
#   POST days/:id/close        o dono: { expected_state } → 200 <home_visit_day>
# Folha de outro escopo por id → 404 (antes de olhar o corpo); equipe alheia
# → 403 out_of_scope; filtro repetido só com [] (escalar → 422 com path).
module HomeVisits
  class DaysController < BaseController
    LIST_KEYS = %i[team_id professional_id from to state before limit].freeze
    CLOSE_KEYS = %w[expected_state].freeze
    DAY_CURSOR = /\A(\d{4}-\d{2}-\d{2})\|([1-9]\d{0,5})\|(\h{8}-\h{4}-\h{4}-\h{4}-\h{12})\z/

    def today
      return unless query_only!(:team_id)
      return unless load_team!
      return render_refusal("cbo_not_allowed") unless %i[acs field].include?(Access.role(@member))

      day = HomeVisitDay.open_on(@member.professional, @team, Time.zone.today).find_by(user_id: Current.user.id)
      return render(json: nil) unless day

      visits = day_visits(day)
      trail!(visits) if visits.any?(&:patient_id)
      render json: Json.day(day, viewer: Current.user).merge(visits: Json.visits(visits, viewer: Current.user))
    end

    def index
      return unless query_only!(*LIST_KEYS)
      return unless load_team!

      scope = list_scope
      return unless scope

      limit = page_limit
      return unless limit

      position = day_cursor
      return if performed?

      if position
        scope = scope.where("(home_visit_days.day, home_visit_days.sequence, home_visit_days.id) < (?, ?, ?::uuid)", *position)
      end
      rows = scope.order(day: :desc, sequence: :desc, id: :desc).includes(:professional, team: :health_unit).limit(limit + 1).to_a
      page = rows.first(limit)
      render json: { items: Json.days(page, viewer: Current.user),
                     next_before: rows.size > limit ? encode_day_cursor(page.last) : nil }
    end

    def show
      return unless query_only!

      day = readable_day
      return render_refusal("not_found") unless day

      visits = day_visits(day)
      trail!(visits) if visits.any?
      render json: Json.day(day, viewer: Current.user).merge(visits: Json.visits(visits, viewer: Current.user))
    end

    def close
      return unless query_only!

      day = uuid?(params[:id]) && HomeVisitDay.find_by(id: params[:id], user_id: Current.user.id)
      return render_refusal("not_found") unless day

      unknown = (body.keys - CLOSE_KEYS).first
      return render_refusal("invalid_request", path: unknown[0, 64]) if unknown

      result = CloseDay.call(day, by: Current.user, closed_by: "user", expected_state: body_param("expected_state"))
      return render_failure(result) if result.failure?

      render json: Json.day(result.payload[:day], viewer: Current.user)
    end

    private

    # Folhas da equipe que quem lê alcança: enfermeiro/médico, todas (ou as
    # de `professional_id`); quem registra, só as suas (outro profissional →
    # 403 out_of_scope); sem papel na visita → 403 out_of_scope. Com os
    # filtros de dia e de estado. nil = já respondeu.
    def list_scope
      professional_id = query_uuid("professional_id")
      return nil if performed?

      scope = HomeVisitDay.where(team_id: @team.id)
      case Access.role(@member)
      when :reader
        scope = scope.where(professional_id: professional_id) if professional_id
      when :acs, :field
        if professional_id && professional_id.downcase != @member.professional_id
          render_refusal("out_of_scope")
          return nil
        end
        scope = scope.where(user_id: Current.user.id)
      else
        render_refusal("out_of_scope")
        return nil
      end

      from = query_date("from")
      to = query_date("to") unless performed?
      states = list_filter("state", HomeVisitDay::STATES) unless performed?
      return nil if performed?

      scope = scope.where(day: from..) if from
      scope = scope.where(day: ..to) if to
      states ? scope.where(state: states) : scope
    end

    # Cursor opaco da lista (Q52): a posição na ordem day DESC, sequence DESC,
    # id DESC — "AAAA-MM-DD|sequence|id" em base64 url-safe. A complementar de
    # um dia passado fica junto do seu dia; o id desempata (paginação estável).
    def encode_day_cursor(day) = Base64.urlsafe_encode64("#{day.day.iso8601}|#{day.sequence}|#{day.id}", padding: false)

    # [dia, sequence, id] | nil (sem before); inválido → 422 invalid_cursor.
    def day_cursor
      raw = params[:before]
      return nil if raw.nil? || raw == ""

      match = raw.is_a?(String) && Base64.urlsafe_decode64(raw).match(DAY_CURSOR)
      raise ArgumentError, "cursor" unless match

      [ Date.iso8601(match[1]), Integer(match[2], 10), match[3].downcase ]
    rescue ArgumentError
      render_refusal("invalid_cursor")
      nil
    end

    # O dono, ou o enfermeiro/médico da equipe; senão nil (404).
    def readable_day
      day = uuid?(params[:id]) && HomeVisitDay.includes(:professional, team: :health_unit).find_by(id: params[:id])
      day if day && (day.user_id == Current.user.id || Access.reads_team?(Current.user, day.team))
    end

    # Todas as visitas da folha (inclusive retiradas), na ordem da ficha.
    def day_visits(day)
      day.home_visits.includes(:micro_area, :patient, home_visit_day: :team, recorded_by_user: :professional,
                                                     withdrawn_by_user: :professional).order(:occurred_at, :id).to_a
    end

    def trail!(visits)
      Trail.visits_viewed!(user: Current.user, home_visit_ids: visits.map(&:id), patient_ids: visits.filter_map(&:patient_id))
    end
  end
end
