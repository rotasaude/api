# Sugestões a confirmar (contrato §4; §11 L5, L7; §12 P3). Só pendentes; sem
# texto clínico. Os comandos não conferem o painel: quem confere é este
# controller (sugestão de outra equipe por id → 404; lista ou aceite para
# equipe alheia → 403 out_of_scope). O AcceptSuggestion nunca roda numa
# transação externa (ordem de travas do Desvio 8). Trilha uma por pessoa
# mostrada; o contador não grava trilha.
module CareLines
  class SuggestionsController < BaseController
    before_action :load_suggestion, only: %i[accept dismiss]

    def index
      team = scoped_team or return
      return render_error(:invalid_filter) if params[:care_line_id].present? && !uuid?(params[:care_line_id])

      scope = CareLineSuggestion.pending_suggestions.where(team_id: team.id).includes(:care_line, :patient, :citizen)
      scope = scope.where(care_line_id: params[:care_line_id]) if params[:care_line_id].present?
      limit = Timeline::Query.limit(params[:limit])
      rows = Cursor.before(scope.order(created_at: :desc, id: :desc), Cursor.decode(params[:before]), :created_at).limit(limit + 1).to_a
      more = rows.size > limit
      rows = rows.first(limit)
      payload = rows.map do |suggestion|
        Trail.viewed!(user: Current.user, patient_id: suggestion.patient_id, citizen_id: suggestion.citizen_id, suggestion_id: suggestion.id)
        Json.suggestion(suggestion)
      end
      render json: { suggestions: payload, next_before: more ? Cursor.encode(rows.last.created_at, rows.last.id) : nil }
    rescue Cursor::Invalid
      render_error(:invalid_cursor)
    end

    def count
      team = scoped_team or return
      render json: { count: CareLineSuggestion.pending_suggestions.where(team_id: team.id).count }
    end

    # De inscrição: { team_id, anchor_date? } → 201 <enrollment>. De
    # encerramento ({}): 200 <enrollment> encerrada (§11 L5).
    def accept
      team = nil
      unless @suggestion.closure?
        team = scoped_team or return
      end
      result = AcceptSuggestion.call(suggestion: @suggestion, by: Current.user, team: team, anchor_date: params[:anchor_date])
      return render_failure(result) if result.failure?

      enrollment = result.payload[:enrollment] || result.payload[:ended]
      row = Evaluation.enrollments([ enrollment ], today: Time.zone.today).fetch(enrollment.id)
      Trail.viewed!(user: Current.user, patient_id: enrollment.patient_id, citizen_id: nil, enrollment_id: enrollment.id)
      last_contact = @suggestion.closure? ? enrollment.contacts.first : nil
      render json: Json.enrollment(enrollment, row: row, last_contact: last_contact), status: @suggestion.closure? ? :ok : :created
    end

    def dismiss
      result = DismissSuggestion.call(suggestion: @suggestion, reason: params[:reason], by: Current.user)
      return render_failure(result) if result.failure?

      render json: { id: @suggestion.id, status: "dismissed" }
    end

    private

    def load_suggestion
      @suggestion = uuid?(params[:id]) && CareLineSuggestion.includes(:team).find_by(id: params[:id])
      not_found unless @suggestion && Access.panel?(Current.user, @suggestion.team)
    end
  end
end
