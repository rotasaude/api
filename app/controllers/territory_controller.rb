# Território da cidade (ADR 0023; spec 2026-09-28-module-11-territory §4.1):
# bairros e cobertura, só municipal_admin, sem step-up (nada disso autoriza
# ato clínico nem expõe dado de cidadão). Prefixo único /territory: uma
# entrada só no proxy de dev do dashboard.
class TerritoryController < ApplicationController
  include Authentication
  include AttendanceAccess

  wrap_parameters false

  ERROR_STATUS = {
    blank_name: :unprocessable_entity, name_taken: :unprocessable_entity, inactive_unit: :unprocessable_entity,
    inactive_neighborhood: :unprocessable_entity, not_found: :not_found
  }.freeze

  before_action :require_territory_admin
  before_action :set_neighborhood, except: %i[index create]

  def index
    neighborhoods = Neighborhood.includes(:health_units).order(:name)
    render json: { neighborhoods: neighborhoods.map { |n| neighborhood_json(n) } }
  end

  def create
    return refuse(:blank_name) unless params[:name].is_a?(String)

    respond(Territory::CreateNeighborhood.call(name: params[:name], by: Current.user), status: :created)
  end

  def update
    return refuse(:blank_name) unless params[:name].is_a?(String)

    respond(Territory::RenameNeighborhood.call(neighborhood: @neighborhood, name: params[:name], by: Current.user))
  end

  def deactivate
    respond(Territory::SetNeighborhoodActive.call(neighborhood: @neighborhood, active: false, by: Current.user))
  end

  def activate
    respond(Territory::SetNeighborhoodActive.call(neighborhood: @neighborhood, active: true, by: Current.user))
  end

  def coverage
    ids = params[:health_unit_ids]
    return refuse(:inactive_unit) unless ids.is_a?(Array) && ids.all?(String)

    respond(Territory::ReplaceCoverage.call(neighborhood: @neighborhood, health_unit_ids: ids, by: Current.user))
  end

  private

  def require_territory_admin
    forbid("missing_role") unless CitizenVerificationPolicy.new(Current.user, nil).manage?
  end

  def set_neighborhood
    @neighborhood = Neighborhood.find_by(id: params[:id])
    refuse(:not_found) unless @neighborhood
  end

  def refuse(reason)
    render json: { error: reason.to_s }, status: ERROR_STATUS.fetch(reason)
  end

  def respond(result, status: :ok)
    return render_failure(result, ERROR_STATUS) if result.failure?

    neighborhood = Neighborhood.includes(:health_units).find(result.payload[:neighborhood].id)
    render json: { neighborhood: neighborhood_json(neighborhood) }, status: status
  end

  def neighborhood_json(neighborhood)
    {
      id: neighborhood.id, name: neighborhood.name, source: neighborhood.source, active: neighborhood.active,
      units: neighborhood.health_units.sort_by(&:name).map { |u| { id: u.id, name: u.name, active: u.active } }
    }
  end
end
