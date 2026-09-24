# Balcão da UBS (spec 2026-09-24-citizen-presencial-verification §4–§7).
#   POST /attendance/lookup                   {cpf, code}                    citizen_verifier
#   POST /attendance/verifications             {cpf, code, document_checked}  citizen_verifier
#   GET  /attendance/verifications?cpf=                                      municipal_admin
#   POST /attendance/verifications/:id/revoke {reason}                       municipal_admin
class AttendanceController < ApplicationController
  include Authentication

  # Mesmo delegador de MfaController::RateLimitStore.
  module RateLimitStore
    def self.increment(...) = Rails.cache.increment(...)
  end

  ERROR_STATUS = {
    invalid_cpf: :unprocessable_entity, invalid_code: :unprocessable_entity, code_expired: :unprocessable_entity,
    code_exhausted: :unprocessable_entity, document_check_required: :unprocessable_entity,
    reason_too_short: :unprocessable_entity, already_verified: :conflict, already_revoked: :conflict,
    own_verification: :forbidden
  }.freeze

  before_action :require_verifier, only: %i[lookup verify]
  before_action :require_admin, only: %i[index revoke]

  rate_limit to: 30, within: 10.minutes, only: %i[lookup verify], name: "attendance",
             by: -> { Current.user&.id || request.remote_ip }, store: RateLimitStore,
             with: -> { render json: { error: "too_many_requests" }, status: :too_many_requests }

  def lookup
    result = Citizens::LookupForVerification.call(cpf: params[:cpf], code: params[:code])
    return render_failure(result) if result.failure?

    citizen = result.payload[:citizen]
    render json: {
      citizen: {
        id: citizen.id, cpf_masked: citizen.cpf_masked, phone_masked: CitizenIdentity::Phone.mask(citizen.phone),
        created_at: citizen.created_at.iso8601, verification_level: citizen.verification_level
      },
      triages: result.payload[:triages].map { |t| { date: t[:date].iso8601, protocol_name: t[:protocol_name] } }
    }
  end

  def verify
    result = Citizens::Verify.call(cpf: params[:cpf], code: params[:code],
                                   document_checked: params[:document_checked] == true, by: Current.user)
    return render_failure(result) if result.failure?

    v = result.payload[:verification]
    render json: { verification: { id: v.id, citizen_id: v.citizen_id, verified_at: v.verified_at.iso8601 } },
           status: :created
  end

  def index
    digits = CitizenIdentity::Cpf.normalize(params[:cpf])
    return render json: { error: "invalid_cpf" }, status: :unprocessable_entity unless digits

    rows = CitizenVerification.joins(:citizen).where(citizens: { cpf: digits })
                              .includes(:citizen, :verified_by_user, :revoked_by_user).order(verified_at: :desc)
    render json: { verifications: rows.map { |v| verification_json(v) } }
  end

  def revoke
    verification = CitizenVerification.find_by(id: params[:id])
    return render json: { error: "not_found" }, status: :not_found unless verification

    result = Citizens::RevokeVerification.call(verification: verification, reason: params[:reason], by: Current.user)
    return render_failure(result) if result.failure?

    render json: { verification: verification_json(verification.reload) }
  end

  private

  def require_verifier
    forbid unless CitizenVerificationPolicy.new(Current.user, nil).verify?
  end

  def require_admin
    forbid unless CitizenVerificationPolicy.new(Current.user, nil).manage?
  end

  def forbid
    render json: { error: "forbidden" }, status: :forbidden
  end

  def render_failure(result)
    payload = { error: result.reason.to_s }
    payload[:verified_at] = result.details[:verified_at].iso8601 if result.details[:verified_at]
    render json: payload, status: ERROR_STATUS.fetch(result.reason, :unprocessable_entity)
  end

  def verification_json(v)
    {
      id: v.id, verified_at: v.verified_at.iso8601, verified_by: v.verified_by_user.email_address,
      phone_masked: CitizenIdentity::Phone.mask(v.citizen.phone), active: v.active?,
      revoked_at: v.revoked_at&.iso8601, revoked_by: v.revoked_by_user&.email_address, revoke_reason: v.revoke_reason
    }
  end
end
