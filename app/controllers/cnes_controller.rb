# app/controllers/cnes_controller.rb
# CNES da cidade (ADR 0028; contratos §5.2): propostas e divergências contra o
# retrato mais recente; confirmar exige step-up. Só municipal_admin.
class CnesController < ApplicationController
  include Authentication
  include MfaStepUp

  wrap_parameters false

  before_action :require_admin

  def show
    data = Cnes::Proposal.for(Current.city)
    snapshot = data[:snapshot]
    render json: {
      snapshot: snapshot && { competence: snapshot.competence, imported_at: snapshot.imported_at.iso8601 },
      proposals: data[:proposals].map { |p| p.except(:target) },
      divergences: data[:divergences]
    }
  end

  def apply
    return require_step_up! unless reauthenticated_recently?

    result = Cnes::Apply.call(city: Current.city, proposal_ids: request.request_parameters["proposal_ids"], by: Current.user)
    return render(json: { error: result.reason.to_s }, status: :unprocessable_entity) if result.failure?

    render json: result.payload
  end

  private

  def require_admin
    render json: { error: "missing_role" }, status: :forbidden unless IntegrationPolicy.new(Current.user, nil).manage?
  end
end
