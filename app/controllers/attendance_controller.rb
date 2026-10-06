# Balcão da UBS (spec 2026-09-24-citizen-presencial-verification §4–§7).
#   POST /attendance/lookup                   {cpf, code}                    citizen_verifier
#   POST /attendance/verifications             {cpf, code, document_checked, birth_date, sex, gender_identity?, cadsus_confirmed?}  citizen_verifier
#   POST /attendance/cadsus_lookup              {cpf, code}                    citizen_verifier + cadsus_lookup
#   POST /attendance/verifications/search      {cpf}                          municipal_admin
#   POST /attendance/verifications/:id/revoke {reason}                       municipal_admin
# O CPF do histórico vai no corpo, não na URL (LGPD: URLs acabam em logs de
# acesso e no histórico do navegador).
class AttendanceController < ApplicationController
  include Authentication
  include AttendanceAccess
  include FeatureGate

  ERROR_STATUS = {
    invalid_cpf: :unprocessable_entity, invalid_code: :unprocessable_entity, code_expired: :unprocessable_entity,
    code_exhausted: :unprocessable_entity, document_check_required: :unprocessable_entity,
    invalid_birth_date: :unprocessable_entity, invalid_sex: :unprocessable_entity,
    invalid_gender_identity: :unprocessable_entity,
    reason_too_short: :unprocessable_entity, already_verified: :conflict, already_revoked: :conflict,
    own_verification: :forbidden, cadsus_lookup_missing: :conflict
  }.freeze

  before_action :require_verifier, only: %i[lookup verify cadsus_lookup]
  require_feature "cadsus_lookup", only: :cadsus_lookup
  before_action :require_admin, only: %i[search revoke]

  rate_limit to: 30, within: 10.minutes, only: %i[lookup verify cadsus_lookup], name: "attendance",
             by: -> { Current.user&.id || request.remote_ip }, store: AttendanceAccess::RateLimitStore,
             with: -> { render json: { error: "too_many_requests" }, status: :too_many_requests }

  def lookup
    result = Citizens::LookupForVerification.call(cpf: params[:cpf], code: params[:code])
    return render_failure(result, ERROR_STATUS) if result.failure?

    citizen = result.payload[:citizen]
    render json: {
      citizen: {
        id: citizen.id, cpf_masked: citizen.cpf_masked, phone_masked: CitizenIdentity::Phone.mask(citizen.phone),
        created_at: citizen.created_at.iso8601, verification_level: citizen.verification_level,
        profile: Citizens::ProfileJson.call(citizen)
      },
      triages: result.payload[:triages].map { |t| { date: t[:date].iso8601, protocol_name: t[:protocol_name] } }
    }
  end

  def verify
    result = Citizens::Verify.call(
      cpf: params[:cpf], code: params[:code], document_checked: params[:document_checked] == true, by: Current.user,
      birth_date: params[:birth_date], sex: params[:sex],
      gender_identity: params.key?(:gender_identity) ? params[:gender_identity] : Citizens::Verify::UNCHANGED,
      cadsus_confirmed: params[:cadsus_confirmed] == true, session_id: Current.session&.id
    )
    return render_failure(result, ERROR_STATUS) if result.failure?

    v = result.payload[:verification]
    render json: { verification: { id: v.id, citizen_id: v.citizen_id, verified_at: v.verified_at.iso8601 } },
           status: :created
  end

  # ADR 0028 (contratos §5.4): o par sai do mesmo CPF + código do lookup, sem
  # consumir o código; a resposta nunca traz nome, mãe, endereço nem CPF.
  def cadsus_lookup
    match = Citizens::VerificationCodeMatch.call(cpf: params[:cpf], code: params[:code])
    return render_failure(match, ERROR_STATUS) if match.failure?

    result = Cadsus::Lookup.call(citizen: match.payload[:citizen], by: Current.user, session: Current.session,
                                 city: Current.city)
    return render(json: { error: "cadsus_unavailable" }, status: :service_unavailable) if result.failure?

    render json: result.payload
  end

  def search
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
    return render_failure(result, ERROR_STATUS) if result.failure?

    render json: { verification: verification_json(verification.reload) }
  end

  private

  def verification_json(v)
    {
      id: v.id, verified_at: v.verified_at.iso8601, verified_by: v.verified_by_user.email_address,
      phone_masked: CitizenIdentity::Phone.mask(v.citizen.phone), active: v.active?,
      revoked_at: v.revoked_at&.iso8601, revoked_by: v.revoked_by_user&.email_address, revoke_reason: v.revoke_reason
    }
  end
end
