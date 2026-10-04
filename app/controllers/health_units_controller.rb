# Cadastro de unidades de saúde (spec 2026-09-24-citizen-attendance-check-in
# §4, §6): leitura para citizen_verifier, health_professional e
# municipal_admin; escrita só para municipal_admin.
class HealthUnitsController < ApplicationController
  include Authentication
  include AttendanceAccess

  # Endereço da unidade (ADR 0023; spec 2026-09-28-module-11-territory §4.1).
  ADDRESS_FIELDS = %w[address_street address_number address_complement address_zip neighborhood_id].freeze

  before_action :require_unit_reader, only: %i[index]
  before_action :require_admin, only: %i[all create update deactivate activate drain]
  before_action :set_unit, only: %i[update deactivate activate drain]

  def index
    render json: { units: HealthUnit.active_units.map { |u| unit_json(u) } }
  end

  # Para o admin: cada unidade com quantos pedidos vivos e horários marcados
  # ainda a prendem (o que "Esvaziar unidade" moveria; api#29).
  def all
    requests = AppointmentRequest.live_requests.group(:target_unit_id).count
    appointments = Appointment.live.group(:health_unit_id).count
    render json: { units: HealthUnit.order(:name).map do |u|
      unit_json(u, include_active: true).merge(live_requests_count: requests[u.id] || 0,
                                               live_appointments_count: appointments[u.id] || 0)
    end }
  end

  # POST /attendance/units/:id/drain { target_unit_id, reason } (api#29; F-09.3)
  def drain
    return render json: { error: "not_found" }, status: :not_found unless @unit

    result = HealthUnits::Drain.call(unit: @unit, target_unit_id: params[:target_unit_id], reason: params[:reason],
                                     by: Current.user)
    return render json: { error: result.reason.to_s }, status: :unprocessable_entity if result.failure?

    render json: { drain: { id: result.payload[:drain].id, requests_count: result.payload[:requests],
                            appointments_count: result.payload[:appointments] } }
  end

  def create
    unit = HealthUnit.new(name: params[:name], kind: params[:kind])
    error = assign_address(unit)
    return render(json: { error: error }, status: :unprocessable_entity) if error
    return render_invalid(unit) unless unit.save

    render json: { unit: unit_json(unit, include_active: true) }, status: :created
  rescue ActiveRecord::RecordNotUnique
    render json: { error: "unit_name_taken" }, status: :unprocessable_entity
  end

  def update
    return render json: { error: "not_found" }, status: :not_found unless @unit

    @unit.assign_attributes(name: params[:name], kind: params[:kind])
    error = assign_address(@unit)
    return render(json: { error: error }, status: :unprocessable_entity) if error
    return render_invalid(@unit) unless @unit.save

    render json: { unit: unit_json(@unit, include_active: true) }
  rescue ActiveRecord::RecordNotUnique
    render json: { error: "unit_name_taken" }, status: :unprocessable_entity
  end

  def deactivate
    return render json: { error: "not_found" }, status: :not_found unless @unit

    # FOR UPDATE na unidade: espera o check-in ou encaminhamento em curso
    # (HealthUnit.lock_active!) e só então confere o que está aberto.
    conflict = nil
    @unit.with_lock do
      conflict = deactivation_conflict
      @unit.update!(active: false) unless conflict
    end
    return render json: { error: conflict }, status: :conflict if conflict

    render json: { unit: unit_json(@unit, include_active: true) }
  end

  def activate
    return render json: { error: "not_found" }, status: :not_found unless @unit

    @unit.update!(active: true)
    render json: { unit: unit_json(@unit, include_active: true) }
  end

  private

  def deactivation_conflict
    return "unit_has_open_attendances" if Attendance.open_attendances.where(health_unit: @unit).exists?

    "unit_has_open_requests" if AppointmentRequest.live_requests.where(target_unit: @unit).exists?
  end

  def require_unit_reader
    policy = CitizenVerificationPolicy.new(Current.user, nil)
    forbid unless policy.verify? || policy.care? || policy.manage?
  end

  def set_unit
    @unit = HealthUnit.find_by(id: params[:id])
  end

  # Só as chaves presentes no corpo mudam: um cliente que ainda não manda o
  # endereço (dashboard anterior ao módulo 11) não o apaga ao salvar nome e
  # tipo. Valor não escalar é recusado com o código do campo. Bairro precisa
  # existir (inativo é aceito: é onde a unidade fica, não uma escolha nova).
  def assign_address(unit)
    ADDRESS_FIELDS.each do |field|
      next unless params.key?(field)

      value = params[field]
      return address_error(field) unless value.nil? || value.is_a?(String)
      if field == "neighborhood_id" && value.present? && !Neighborhood.exists?(id: value)
        return "invalid_neighborhood"
      end

      unit.public_send("#{field}=", value.presence)
    end
    nil
  end

  def address_error(field)
    { "address_zip" => "invalid_zip", "neighborhood_id" => "invalid_neighborhood" }.fetch(field, "invalid_unit")
  end

  def render_invalid(unit)
    if unit.errors.details[:name]&.any? { |e| e[:error] == :taken }
      render json: { error: "unit_name_taken" }, status: :unprocessable_entity
    elsif unit.errors.details[:kind].present?
      render json: { error: "invalid_kind" }, status: :unprocessable_entity
    elsif unit.errors.details[:address_zip].present?
      render json: { error: "invalid_zip" }, status: :unprocessable_entity
    else
      render json: { error: "invalid_unit" }, status: :unprocessable_entity
    end
  end

  def unit_json(unit, include_active: false)
    json = { id: unit.id, name: unit.name, kind: unit.kind }.merge(unit.slice(*ADDRESS_FIELDS).symbolize_keys)
    json[:active] = unit.active if include_active
    json
  end
end
