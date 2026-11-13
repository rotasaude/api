# Aparelhos de campo do próprio usuário, pelo dashboard (módulo 24b, ADR 0052;
# contrato §9.1; Q7, Q20, Q21):
#   GET  /field_devices              os do usuário, com status active | inactive | revoked
#   POST /field_devices              { name } → 201 { device, token, qr_payload }; step-up;
#                                    Tabela 7 com vínculo ativo em equipe 70/76; home_visits utilizável
#   POST /field_devices/:id/revoke   só o dono (os outros: 404), sem step-up
# O token e o qr_payload só saem no 201, com Cache-Control: no-store; nunca na
# URL nem no log (filter_parameters cobre token e qr_payload). Listar e revogar
# não dependem do interruptor: um aparelho perdido se revoga sempre.
class FieldDevicesController < ApplicationController
  include Authentication
  include MfaStepUp
  include ::HomeVisitsGate

  wrap_parameters false

  FAILURE_STATUS = { cbo_not_allowed: :forbidden, device_already_revoked: :conflict }.freeze

  before_action :require_home_visits!, only: :create
  before_action :require_step_up!, only: :create

  def index
    devices = FieldDevice.includes(:user, :professional).where(user_id: Current.user.id).order(created_at: :desc, id: :desc).to_a
    render json: { items: FieldSync::Json.devices(devices) }
  end

  def create
    result = FieldDevices::Register.call(user: Current.user, name: request.request_parameters["name"])
    return render_failure(result) if result.failure?

    device = result.payload.fetch(:device)
    token = result.payload.fetch(:token)
    response.headers["Cache-Control"] = "no-store"
    render json: { device: FieldSync::Json.device(device, owner_state: "active"),
                   token: token, qr_payload: FieldSync::Token.qr_payload(host: request.host, token: token) },
           status: :created
  end

  def revoke
    device = FieldDevice.find_by(id: params[:id], user_id: Current.user.id)
    return render(json: { error: "not_found" }, status: :not_found) unless device

    result = FieldDevices::Revoke.call(device, by: Current.user, reason: "user")
    return render_failure(result) if result.failure?

    render json: { device: FieldSync::Json.devices([ device ]).first }
  end

  private

  def render_failure(result)
    payload = { error: result.reason.to_s }
    payload[:path] = result.details[:path] if result.details.key?(:path)
    render json: payload, status: FAILURE_STATUS.fetch(result.reason, :unprocessable_entity)
  end
end
