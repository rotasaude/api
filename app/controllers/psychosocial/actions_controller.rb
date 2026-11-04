# Ações do CAPS (ADR 0049; contrato §4, P12, P13, P23):
#   POST /psychosocial/actions                { health_unit_id, sigtap_code, performed_at, place, quantity?, notes?,
#                                               authorization_number?, group_id?, participants: [...] }
#        → 201 <detalhe>, sem trilha (quem grava digitou); a crítica recusa
#        com 422 { error: "action_rejected", problems: [ { error, path, participant_index? } ] }
#   GET  /psychosocial/actions?enrollment_id&before
#        lista da matrícula, sem notas e sem trilha, da mais nova para a mais
#        antiga (performed_at, id), em páginas de PAGE, com `next_before`
#   GET  /psychosocial/actions/:id             <detalhe> com notas; trilha `resource: "action"` por paciente participante
#   POST /psychosocial/actions/:id/cancel      { reason } → <item>
# Matrícula ou ação de outro CAPS (ou de CAPS onde quem pede não está lotado)
# → 404. Texto e participantes só no corpo; ids na URL.
module Psychosocial
  class ActionsController < BaseController
    PAGE = 200
    CANCEL_KEYS = %w[reason].freeze

    before_action :load_action, only: %i[show cancel]

    def index
      return forbid unless Access.staff?(Current.user)
      return unless query_only!("enrollment_id", "before")

      query = request.query_parameters
      return render_refusal("enrollment_id") unless uuid?(query["enrollment_id"])

      enrollment = PsychosocialEnrollment.find_by(id: query["enrollment_id"])
      return not_found unless enrollment && Access.can_read?(Current.user, enrollment)

      scope = PsychosocialAction.where(health_unit_id: enrollment.health_unit_id)
                                .where(id: PsychosocialActionParticipant.where(psychosocial_enrollment_id: enrollment.id)
                                                                        .select(:psychosocial_action_id))
      if query.key?("before")
        at, id = CareRegulation::Cursor.decode_page(query["before"])
        scope = scope.where("(psychosocial_actions.performed_at, psychosocial_actions.id) < (?, ?)", at, id)
      end
      rows = scope.includes(professional_user: :professional).order(performed_at: :desc, id: :desc).limit(PAGE + 1).to_a
      page = rows.first(PAGE)
      counts = PsychosocialActionParticipant.where(psychosocial_action_id: page.map(&:id)).group(:psychosocial_action_id).count
      cache = Billing::SigtapCache.new
      render json: { items: page.map { |action| Json.action_item(action, count: counts.fetch(action.id, 0), cache: cache) },
                     next_before: rows.size > PAGE ? CareRegulation::Cursor.encode_page(page.last.performed_at, page.last.id) : nil }
    rescue CareRegulation::Cursor::Invalid
      render_refusal("before", "invalid_cursor")
    end

    def show
      @caps_action.psychosocial_action_participants.filter_map(&:patient_id).uniq.each do |patient_id|
        Trail.viewed!(patient: patient_id, user: Current.user, resource: "action")
      end
      render json: Json.action(@caps_action)
    end

    def create
      return unless query_only!

      unit = staff_unit!(body_param("health_unit_id"))
      return unless unit

      result = RecordAction.call(attrs: body, unit: unit, by: Current.user, link: @link)
      return render_failure(result) if result.failure?

      render json: Json.action(result.payload.fetch(:action)), status: :created
    end

    def cancel
      unknown = (body.keys - CANCEL_KEYS).first
      return render_refusal(unknown.to_s[0, KEY_PATH_MAX]) if unknown

      result = CancelAction.call(action: @caps_action, reason: body_param("reason"), by: Current.user)
      return render_failure(result) if result.failure?

      action = result.payload.fetch(:action)
      render json: Json.action_item(action, count: action.psychosocial_action_participants.size)
    end

    private

    # A ação da URL: sem o papel do CAPS → 403 missing_role; id malformado,
    # inexistente ou de CAPS em que quem pede não está lotado → 404.
    def load_action
      return forbid unless Access.staff?(Current.user)
      return unless query_only!

      @caps_action = uuid?(params[:id]) ? PsychosocialAction.includes(psychosocial_action_participants: :patient).find_by(id: params[:id]) : nil
      not_found unless @caps_action && Access.can_read?(Current.user, @caps_action)
    end
  end
end
