# Tipos de atendimento (ADR 0029 §3.1; contratos §3, §9). Leitura para quem
# monta agenda, marca, atende ou escreve protocolo; escrita só municipal_admin,
# sem step-up (tipo não muda quem pode fazer o quê).
class AppointmentTypesController < ApplicationController
  include Authentication
  include AttendanceAccess

  wrap_parameters false

  READERS = %w[municipal_admin citizen_verifier health_professional protocol_author protocol_reviewer].freeze
  ERROR_STATUS = {
    invalid_key: :unprocessable_entity, key_taken: :unprocessable_entity, invalid_name: :unprocessable_entity,
    invalid_duration: :unprocessable_entity, invalid_cbo_prefixes: :unprocessable_entity,
    platform_type_locked: :unprocessable_entity, invalid: :unprocessable_entity
  }.freeze

  before_action :require_reader, only: :index
  before_action :require_admin, except: :index

  def index
    render json: { types: AppointmentType.listed.map { |t| type_json(t) } }
  end

  def create
    result = Scheduling::SaveAppointmentType.create(attrs: body, by: Current.user)
    return render_failure(result, ERROR_STATUS) if result.failure?

    render json: type_json(result.payload[:type]), status: :created
  end

  def update
    type = AppointmentType.find_by(key: params[:key].to_s)
    return render(json: { error: "not_found" }, status: :not_found) unless type

    result = Scheduling::SaveAppointmentType.update(type: type, attrs: body, by: Current.user)
    return render_failure(result, ERROR_STATUS) if result.failure?

    render json: type_json(result.payload[:type])
  end

  private

  def require_reader
    forbid unless Current.user && Membership.active.where(user: Current.user, role: READERS).exists?
  end

  def body = request.request_parameters.to_h

  def type_json(t)
    { key: t.key, name: t.name, duration_minutes: t.duration_minutes, cbo_prefixes: Array(t.cbo_prefixes),
      active: t.active, origin: t.origin }
  end
end
