# Cadastro de unidades de saúde (spec 2026-09-24-citizen-attendance-check-in
# §4, §6): leitura para citizen_verifier e municipal_admin; escrita só para
# municipal_admin.
class HealthUnitsController < ApplicationController
  include Authentication
  include AttendanceAccess

  before_action :require_verifier_or_admin, only: %i[index]
  before_action :require_admin, only: %i[all create update deactivate activate]
  before_action :set_unit, only: %i[update deactivate activate]

  def index
    render json: { units: HealthUnit.active_units.map { |u| unit_json(u) } }
  end

  def all
    render json: { units: HealthUnit.order(:name).map { |u| unit_json(u, include_active: true) } }
  end

  def create
    unit = HealthUnit.new(name: params[:name], kind: params[:kind])
    return render_invalid(unit) unless unit.save

    render json: { unit: unit_json(unit, include_active: true) }, status: :created
  rescue ActiveRecord::RecordNotUnique
    render json: { error: "unit_name_taken" }, status: :unprocessable_entity
  end

  def update
    return render json: { error: "not_found" }, status: :not_found unless @unit

    return render_invalid(@unit) unless @unit.update(name: params[:name], kind: params[:kind])

    render json: { unit: unit_json(@unit, include_active: true) }
  rescue ActiveRecord::RecordNotUnique
    render json: { error: "unit_name_taken" }, status: :unprocessable_entity
  end

  def deactivate
    return render json: { error: "not_found" }, status: :not_found unless @unit

    @unit.update!(active: false)
    render json: { unit: unit_json(@unit, include_active: true) }
  end

  def activate
    return render json: { error: "not_found" }, status: :not_found unless @unit

    @unit.update!(active: true)
    render json: { unit: unit_json(@unit, include_active: true) }
  end

  private

  def require_verifier_or_admin
    policy = CitizenVerificationPolicy.new(Current.user, nil)
    forbid unless policy.verify? || policy.manage?
  end

  def set_unit
    @unit = HealthUnit.find_by(id: params[:id])
  end

  def render_invalid(unit)
    if unit.errors.details[:name]&.any? { |e| e[:error] == :taken }
      render json: { error: "unit_name_taken" }, status: :unprocessable_entity
    elsif unit.errors.details[:kind].present?
      render json: { error: "invalid_kind" }, status: :unprocessable_entity
    else
      render json: { error: "invalid_unit" }, status: :unprocessable_entity
    end
  end

  def unit_json(unit, include_active: false)
    json = { id: unit.id, name: unit.name, kind: unit.kind }
    json[:active] = unit.active if include_active
    json
  end
end
