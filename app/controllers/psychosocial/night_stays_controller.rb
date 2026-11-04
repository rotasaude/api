# Acolhimento noturno (ADR 0049; contrato §5, P13, P25, P36):
#   POST /psychosocial/night_stays            { bed_id, enrollment_id, started_at, expected_end_at, reassessment?: { reason } }
#        → 201 <detalhe>, sem trilha (quem grava digitou); 409 bed_taken | already_staying;
#        422 night_limit_reached { used, limit, window_days, rule }
#   GET  /psychosocial/night_stays/:id        <detalhe>; trilha `resource: "night_stay"`
#   POST /psychosocial/night_stays/:id/close  { ended_at, reason, reassessment?: { reason } }
#        → <detalhe> com a trilha (traz a reavaliação de quem deu entrada);
#        uma ação RAAS por noite; 422 month_closed | action_rejected | night_limit_reached
# O CAPS é o do leito (entrada) ou o da permanência: só a equipe lotada nele.
# Permanência de outro CAPS → 404. Motivos só no corpo; ids na URL.
module Psychosocial
  class NightStaysController < BaseController
    CLOSE_KEYS = %w[ended_at reason reassessment].freeze

    before_action :load_stay, only: %i[show close]

    def create
      return forbid unless Access.staff?(Current.user)
      return unless query_only!

      bed_id = body_param("bed_id")
      bed = uuid?(bed_id) ? PsychosocialBed.find_by(id: bed_id.downcase, active: true) : nil
      return render_refusal("bed_id") unless bed

      unit = staff_unit!(bed.health_unit_id)
      return unless unit

      result = StartNightStay.call(attrs: body, by: Current.user, link: @link)
      return render_failure(result) if result.failure?

      render json: detail(result.payload.fetch(:stay)), status: :created
    end

    def show
      Trail.viewed!(patient: @stay.patient_id, user: Current.user, resource: "night_stay")
      render json: detail(@stay)
    end

    def close
      unknown = (body.keys - CLOSE_KEYS).first
      return render_refusal(unknown.to_s[0, KEY_PATH_MAX]) if unknown

      result = CloseNightStay.call(stay: @stay, ended_at: body_param("ended_at"), reason: body_param("reason"), by: Current.user,
                                   link: Access.link(Current.user, @stay.health_unit_id), reassessment: body_param("reassessment"))
      return render_failure(result) if result.failure?

      stay = result.payload.fetch(:stay)
      Trail.viewed!(patient: stay.patient_id, user: Current.user, resource: "night_stay")
      render json: detail(stay)
    end

    private

    # A permanência da URL: sem o papel do CAPS → 403 missing_role; id
    # malformado, inexistente ou de CAPS em que quem pede não está lotado → 404.
    def load_stay
      return forbid unless Access.staff?(Current.user)
      return unless query_only!

      @stay = uuid?(params[:id]) ? PsychosocialNightStay.find_by(id: params[:id].downcase) : nil
      not_found unless @stay && Access.can_read?(Current.user, @stay)
    end

    def detail(stay)
      users = [ stay.started_by_user_id, stay.closed_by_user_id, stay.reassessed_by_user_id ].compact
      Json.night_stay(stay, cbos: Access.cbos(users, stay.health_unit_id))
    end
  end
end
