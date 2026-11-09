# Administração das TVs da sala de espera (ADR 0050; contrato §8 e §14 Q8;
# preflight C-16, C-17), sessão do dashboard, só o municipal_admin; escrita
# com step-up (401 mfa_required):
#   GET   /waiting_room/displays?health_unit_id=  → { items }
#   POST  /waiting_room/displays                   {health_unit_id, name, active?, show_wait_times?} → 201 TV
#   PATCH /waiting_room/displays/:id               {name?, active?, show_wait_times?} → TV (active: false revoga)
#   POST  /waiting_room/displays/:id/pairing_code  → 201 { code, expires_at } (o código só aqui)
#   POST  /waiting_room/displays/:id/revoke        → TV
# A TV: { id, health_unit_id, name, active, show_wait_times, paired, paired_at,
# last_seen_at, revoked, revoked_at } — nunca o token nem os digests.
module WaitingRoom
  class DisplaysController < BaseController
    include Authentication
    include MfaStepUp

    before_action :require_waiting_room!
    before_action { forbid unless Current.user.has_role?("municipal_admin") }
    before_action :require_step_up!, only: %i[create update pairing_code revoke]
    before_action :find_display, only: %i[update pairing_code revoke]

    def index
      return unless query_only!("health_unit_id")

      unit_id = params[:health_unit_id]
      return render_refusal("health_unit_id") unless uuid?(unit_id)
      return not_found unless HealthUnit.exists?(id: unit_id)

      render json: { items: WaitingRoomDisplay.where(health_unit_id: unit_id).order(:name, :id).map { |d| self.class.json(d) } }
    end

    def create
      result = SaveDisplay.call(attrs: body, by: Current.user)
      return render_failure(result) if result.failure?

      render json: self.class.json(result.payload.fetch(:display)), status: :created
    end

    def update
      result = SaveDisplay.call(attrs: body, by: Current.user, display: @display)
      return render_failure(result) if result.failure?

      render json: self.class.json(result.payload.fetch(:display))
    end

    def pairing_code
      result = IssuePairingCode.call(display: @display, by: Current.user)
      return render_failure(result) if result.failure?

      response.headers["Cache-Control"] = "no-store"
      render json: { code: result.payload.fetch(:code), expires_at: result.payload.fetch(:expires_at).iso8601 }, status: :created
    end

    def revoke
      result = Revoke.call(display: @display, by: Current.user)
      render json: self.class.json(result.payload.fetch(:display))
    end

    def self.json(display)
      { id: display.id, health_unit_id: display.health_unit_id, name: display.name, active: display.active,
        show_wait_times: display.show_wait_times, paired: display.paired?, paired_at: display.paired_at&.iso8601,
        last_seen_at: display.last_seen_at&.iso8601, revoked: display.revoked?, revoked_at: display.revoked_at&.iso8601 }
    end

    private

    def find_display
      @display = uuid?(params[:id]) ? WaitingRoomDisplay.find_by(id: params[:id]) : nil
      not_found unless @display
    end
  end
end
