# ADR 0026: exclusão do cadastro (Art. 18), no posto, por duas pessoas.
#   POST /attendance/erasure_requests             {cpf, document_checked}  citizen_verifier
#   GET  /attendance/erasure_requests                                      municipal_admin
#   POST /attendance/erasure_requests/:id/confirm  (step-up)               municipal_admin
#   POST /attendance/erasure_requests/:id/reject   {reason}                municipal_admin
# O CPF vai no corpo, nunca na URL. A listagem nunca devolve o CPF inteiro.
class ErasureRequestsController < ApplicationController
  include Authentication
  include AttendanceAccess
  include MfaStepUp

  ERROR_STATUS = {
    invalid_cpf: :unprocessable_entity, document_check_required: :unprocessable_entity,
    reason_too_short: :unprocessable_entity, citizen_not_found: :not_found,
    already_pending: :conflict, not_pending: :conflict, own_request: :forbidden
  }.freeze

  before_action :require_verifier, only: :create
  before_action :require_admin, only: %i[index confirm reject]

  def create
    result = Citizens::RequestErasure.call(cpf: params[:cpf], document_checked: params[:document_checked] == true,
                                           by: Current.user)
    return render_failure(result, ERROR_STATUS) if result.failure?

    render json: { request: request_json(result.payload[:request]) }, status: :created
  end

  def index
    rows = CitizenErasureRequest.pending.includes(:requested_by_user, :presented_citizen).order(:created_at)
    render json: { requests: rows.map { |r| index_json(r) } }
  end

  def confirm
    request = CitizenErasureRequest.find_by(id: params[:id])
    return render json: { error: "not_found" }, status: :not_found unless request
    return require_step_up! unless reauthenticated_recently?

    result = Citizens::Erase.call(request: request, by: Current.user)
    return render_failure(result, ERROR_STATUS) if result.failure?

    render json: { request: request_json(result.payload[:request]) }
  rescue ActiveRecord::Deadlocked
    # Ordem de lock oposta à do check-in; nada foi gravado, é só tentar de novo.
    render json: { error: "try_again" }, status: :conflict
  end

  def reject
    request = CitizenErasureRequest.find_by(id: params[:id])
    return render json: { error: "not_found" }, status: :not_found unless request

    result = Citizens::RejectErasure.call(request: request, reason: params[:reason], by: Current.user)
    return render_failure(result, ERROR_STATUS) if result.failure?

    render json: { request: request_json(result.payload[:request]) }
  end

  private

  def request_json(r) = { id: r.id, status: r.status, created_at: r.created_at.iso8601 }

  def index_json(r)
    {
      id: r.id, created_at: r.created_at.iso8601, requested_by: r.requested_by_user.email_address,
      pairs: Citizens::RequestErasure.pairs_of(r.cpf).count,
      phone_masked: CitizenIdentity::Phone.mask(r.presented_citizen.phone)
    }
  end
end
