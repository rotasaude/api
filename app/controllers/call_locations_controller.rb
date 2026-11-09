# Locais de chamada da unidade (ADR 0050; contrato §8 e §14 Q7; preflight
# C-15), sessão do dashboard, atrás do waiting_room_display (403
# feature_disabled):
#   GET   /attendance/call_locations?health_unit_id= → { items, location_required }
#         lê quem chama na unidade: municipal_admin, citizen_verifier e o
#         health_professional com vínculo ativo nela (sem ele → 403 missing_link);
#   POST  /attendance/call_locations     {health_unit_id, name, active?} → 201 local
#   PATCH /attendance/call_locations/:id {name?, active?}                → local
#         só o municipal_admin, com step-up (401 mfa_required).
# `location_required` é o mesmo predicado do Attendances::Call/CallNext
# (WaitingRoom::CallLocations.required?): TV ativa e pareada na unidade.
class CallLocationsController < WaitingRoom::BaseController
  include Authentication
  include MfaStepUp

  before_action :require_waiting_room!
  before_action :require_admin!, only: %i[create update]
  before_action :require_step_up!, only: %i[create update]

  def index
    return unless query_only!("health_unit_id")

    unit_id = params[:health_unit_id]
    return render_refusal("health_unit_id") unless uuid?(unit_id)
    return not_found unless HealthUnit.exists?(id: unit_id)

    reason = reader_refusal(unit_id)
    return forbid(reason) if reason

    locations = CallLocation.where(health_unit_id: unit_id).order(:name, :id)
    render json: { items: locations.map { |l| json(l) },
                   location_required: WaitingRoom::CallLocations.required?(unit_id, enabled: true) }
  end

  def create
    result = WaitingRoom::SaveCallLocation.call(attrs: body, by: Current.user)
    return render_failure(result) if result.failure?

    render json: json(result.payload.fetch(:call_location)), status: :created
  end

  def update
    location = uuid?(params[:id]) ? CallLocation.find_by(id: params[:id]) : nil
    return not_found unless location

    result = WaitingRoom::SaveCallLocation.call(attrs: body, by: Current.user, location: location)
    return render_failure(result) if result.failure?

    render json: json(result.payload.fetch(:call_location))
  end

  private

  def admin? = Current.user.has_role?("municipal_admin")

  def require_admin!
    forbid unless admin?
  end

  # nil quando lê; senão o motivo do 403.
  def reader_refusal(unit_id)
    return nil if admin? || Current.user.has_role?("citizen_verifier")
    return "missing_role" unless Current.user.has_role?("health_professional")

    linked = ProfessionalLink.active.joins(:professional).where(professionals: { user_id: Current.user.id }, health_unit_id: unit_id).exists?
    linked ? nil : "missing_link"
  end

  def json(location) = { id: location.id, health_unit_id: location.health_unit_id, name: location.name, active: location.active }
end
