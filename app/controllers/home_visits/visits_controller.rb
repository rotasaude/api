# /home_visits (contrato §3, §5, §6, §13; Q14, Q17, Q21, Q51; plano, Task 12,
# Desvio 11): as visitas na rota da equipe.
#   POST /home_visits          quem registra (§1): o corpo inteiro vai ao
#                              HomeVisits::Record → 201 { visit, day }; o mesmo
#                              client_uuid já gravado pelo usuário → 200 com a
#                              gravada; de outro usuário → 409 client_uuid_conflict
#   GET  /home_visits/:id      o dono da folha, o enfermeiro/médico da equipe ou
#                              quem lê a microárea: <home_visit> com note
#   POST /home_visits/:id/withdraw   o dono: { expected_state, reason } → 200
#   GET  /home_visits?team_id=&micro_area_id=&professional_id=&from=&to=&outcome[]=&before=&limit=
#                              "Visitas da equipe": { items (sem note), next_before }
#   GET  /home_visits/count?team_id=&micro_area_id=&from=&to=
#                              { done, refused, absent, withdrawn }, sem trilha
# Toda resposta com visita grava uma trilha clinical_record.viewed (só ids). A
# trilha dos candidatos do 409 duplicate_suspected é do Record. Visita de outro
# escopo por id → 404 (antes de olhar o corpo); microárea ou equipe alheia na
# lista → 403 out_of_scope. Pessoa e texto nunca na query (query_only!).
module HomeVisits
  class VisitsController < BaseController
    LIST_KEYS = %i[team_id micro_area_id professional_id from to outcome before limit].freeze
    COUNT_KEYS = %i[team_id micro_area_id from to].freeze
    WITHDRAW_KEYS = %w[expected_state reason].freeze
    OUTCOMES = Catalog::OUTCOMES.keys.map(&:to_s).freeze

    def create
      return unless query_only!

      result = Record.call(params: body, by: Current.user)
      return render_failure(result) if result.failure?

      visit = load_visits(HomeVisit.where(id: result.payload[:visit].id)).sole
      trail!([ visit ])
      render json: { visit: Json.visits([ visit ], viewer: Current.user).sole, day: Json.day(visit.home_visit_day, viewer: Current.user) },
             status: result.payload[:replayed] ? :ok : :created
    end

    def show
      return unless query_only!

      visit = readable_visit
      return render_refusal("not_found") unless visit

      trail!([ visit ])
      render json: Json.visits([ visit ], viewer: Current.user, note: true).sole
    end

    def withdraw
      return unless query_only!

      visit = uuid?(params[:id]) && HomeVisit.joins(:home_visit_day).find_by(id: params[:id], home_visit_days: { user_id: Current.user.id })
      return render_refusal("not_found") unless visit

      unknown = (body.keys - WITHDRAW_KEYS).first
      return render_refusal("invalid_request", path: unknown[0, 64]) if unknown

      result = Withdraw.call(visit, by: Current.user, expected_state: body_param("expected_state"), reason: body_param("reason"))
      return render_failure(result) if result.failure?

      shown = load_visits(HomeVisit.where(id: visit.id)).sole
      trail!([ shown ])
      render json: Json.visits([ shown ], viewer: Current.user).sole
    end

    def index
      return unless query_only!(*LIST_KEYS)

      scope = team_scope
      return unless scope

      professional_id = query_uuid("professional_id")
      outcomes = list_filter("outcome", OUTCOMES) unless performed?
      limit = page_limit unless performed?
      position = cursor unless performed?
      return if performed?

      scope = scope.where(home_visit_days: { professional_id: professional_id }) if professional_id
      scope = scope.where(outcome: outcomes.map(&:to_i)) if outcomes
      rows = load_visits(CareLines::Cursor.before(scope, position, :occurred_at).order(occurred_at: :desc, id: :desc).limit(limit + 1)).to_a
      page = rows.first(limit)
      trail!(page) if page.any?
      render json: { items: Json.visits(page, viewer: Current.user),
                     next_before: rows.size > limit ? CareLines::Cursor.encode(page.last.occurred_at, page.last.id) : nil }
    end

    def count
      return unless query_only!(*COUNT_KEYS)

      scope = team_scope
      return unless scope

      rows = scope.group(Arel.sql("home_visits.outcome"), Arel.sql("home_visits.withdrawn_at IS NULL")).count
      valid = ->(outcome) { rows.fetch([ outcome, true ], 0) }
      render json: { done: valid.(1), refused: valid.(2), absent: valid.(3),
                     withdrawn: rows.sum { |(_, recorded), total| recorded ? 0 : total } }
    end

    private

    # As visitas da equipe que quem lê alcança, com micro_area_id e from/to:
    #  - enfermeiro/médico: a equipe toda (inclusive fora de área);
    #  - ACS e Tabela 7: as microáreas do escopo e as das suas folhas (fora de
    #    área); microárea fora do escopo → 403 out_of_scope;
    #  - sem papel na visita, equipe alheia ou microárea de outra equipe → 403.
    # nil = já respondeu.
    def team_scope
      return nil unless load_team!

      role = Access.role(@member)
      unless role
        render_refusal("out_of_scope")
        return nil
      end

      area_id = query_uuid("micro_area_id")
      from = query_date("from") unless performed?
      to = query_date("to") unless performed?
      return nil if performed?

      scope = HomeVisit.joins(:home_visit_day).where(home_visit_days: { team_id: @team.id })
      if area_id
        area = MicroArea.find_by(id: area_id)
        unless area
          render_refusal("not_found")
          return nil
        end
        unless area.team_id == @team.id && (role == :reader || Access.reads_micro_area?(Current.user, area))
          render_refusal("out_of_scope")
          return nil
        end
        scope = scope.where(micro_area_id: area.id)
      elsif role != :reader
        reachable = Access.scope(Current.user, @team)[:micro_area_ids]
        scope = scope.where(micro_area_id: reachable).or(scope.where(home_visit_days: { user_id: Current.user.id }))
      end
      scope = scope.where(occurred_at: from.in_time_zone.beginning_of_day..) if from
      scope = scope.where(occurred_at: ...(to + 1).in_time_zone.beginning_of_day) if to
      scope
    end

    # O dono da folha, o enfermeiro/médico da equipe, ou quem lê a microárea
    # da visita; senão nil (404).
    def readable_visit
      visit = uuid?(params[:id]) && load_visits(HomeVisit.where(id: params[:id])).first
      return nil unless visit

      day = visit.home_visit_day
      return visit if day.user_id == Current.user.id || Access.reads_team?(Current.user, day.team)

      visit if visit.micro_area && Access.reads_micro_area?(Current.user, visit.micro_area)
    end

    def load_visits(scope)
      scope.includes(:patient, micro_area: :team, home_visit_day: :team, recorded_by_user: :professional,
                     withdrawn_by_user: :professional)
    end

    def trail!(visits)
      Trail.visits_viewed!(user: Current.user, home_visit_ids: visits.map(&:id), patient_ids: visits.filter_map(&:patient_id))
    end
  end
end
