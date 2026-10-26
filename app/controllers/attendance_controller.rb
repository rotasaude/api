# Balcão da UBS (spec 2026-09-24-citizen-presencial-verification §4–§7).
#   POST /attendance/lookup                   {cpf, code}                    citizen_verifier
#   POST /attendance/verifications             {cpf, code, document_checked, birth_date, sex, gender_identity?, cadsus_confirmed?}  citizen_verifier
#   POST /attendance/cadsus_lookup              {cpf, code}                    citizen_verifier + cadsus_lookup
#   POST /attendance/verifications/search      {cpf}                          municipal_admin
#   POST /attendance/verifications/:id/revoke {reason}                       municipal_admin
#   POST /attendance/verifications/:id/names  {full_name, social_name?, mother_name?}  citizen_verifier
# ADR 0039 (D-U1): verifications e names aceitam também race_color, ethnicity
# e address_* (opcionais), gravados no paciente do par; a resposta só traz
# race_color_set/address_set, nunca os valores.
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
    invalid_gender_identity: :unprocessable_entity, invalid_full_name: :unprocessable_entity,
    invalid_social_name: :unprocessable_entity, invalid_mother_name: :unprocessable_entity,
    reason_too_short: :unprocessable_entity, already_verified: :conflict, already_revoked: :conflict,
    own_verification: :forbidden, cadsus_lookup_missing: :conflict,
    invalid_race_color: :unprocessable_entity, invalid_ethnicity: :unprocessable_entity, ethnicity_required: :unprocessable_entity,
    invalid_zip: :unprocessable_entity, too_long: :unprocessable_entity, invalid_demographics: :unprocessable_entity,
    address_from_household: :unprocessable_entity
  }.freeze

  before_action :require_verifier, only: %i[lookup verify cadsus_lookup names]
  require_feature "cadsus_lookup", only: :cadsus_lookup
  before_action :require_admin, only: %i[search revoke]

  rate_limit to: 30, within: 10.minutes, only: %i[lookup verify cadsus_lookup names], name: "attendance",
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
        profile: Citizens::ProfileJson.call(citizen), names: Citizens::NamesJson.call(citizen),
        # §14 L26: as flags do check-in, do paciente que a gravação acha, antes do formulário.
        **Patients::Demographics.flags(Patients::Demographics.patient_of(citizen))
      },
      triages: result.payload[:triages].map { |t| { date: t[:date].iso8601, protocol_name: t[:protocol_name] } }
    }
  end

  def verify
    # §13 E12: tudo conferido (inclusive raça × etnia com o paciente do CPF) antes de gastar o código.
    demographics = parse_demographics do
      digits = CitizenIdentity::Cpf.normalize(params[:cpf])
      digits && Patient.find_by(cpf: digits)
    end
    return render_failure(demographics, ERROR_STATUS) if demographics.failure?

    result = Citizens::Verify.call(
      cpf: params[:cpf], code: params[:code], document_checked: params[:document_checked] == true, by: Current.user,
      birth_date: params[:birth_date], sex: params[:sex],
      full_name: params.key?(:full_name) ? params[:full_name] : Citizens::NameValues::ABSENT,
      social_name: params[:social_name], mother_name: params[:mother_name],
      gender_identity: params.key?(:gender_identity) ? params[:gender_identity] : Citizens::Verify::UNCHANGED,
      cadsus_confirmed: params[:cadsus_confirmed] == true, session_id: Current.session&.id
    )
    return render_failure(result, ERROR_STATUS) if result.failure?

    v = result.payload[:verification]
    json = { verification: { id: v.id, citizen_id: v.citizen_id, verified_at: v.verified_at.iso8601 } }
    if demographics.payload[:values].any?
      saved = save_demographics(v.citizen, demographics.payload[:values])
      return render_failure(saved, ERROR_STATUS) if saved.failure?

      json.merge!(Patients::Demographics.flags(saved.payload[:patient]))
    end
    render json: json, status: :created
  end

  # ADR 0028 (contratos §5.4): o par sai do mesmo CPF + código do lookup, sem
  # consumir o código; a resposta nunca traz nome, mãe, endereço nem CPF.
  def cadsus_lookup
    match = Citizens::VerificationCodeMatch.call(cpf: params[:cpf], code: params[:code])
    return render_failure(match, ERROR_STATUS) if match.failure?

    result = Cadsus::Lookup.call(citizen: match.payload[:citizen], by: Current.user, session: Current.session,
                                 city: Current.city)
    return render_failure(result, ERROR_STATUS) if result.failure? && result.reason == :already_verified
    return render(json: { error: "cadsus_unavailable" }, status: :service_unavailable) if result.failure?

    render json: result.payload
  end

  # ADR 0031 (contratos §2 e §9): completar os nomes de par já validado (no
  # check-in). :id é a validação ativa.
  def names
    verification = CitizenVerification.find_by(id: params[:id])
    return render json: { error: "not_found" }, status: :not_found unless verification

    citizen = verification.citizen
    # §13 E12: os campos do BPA-I conferidos antes de gravar os nomes.
    demographics = parse_demographics { Patients::Demographics.patient_of(citizen) }
    return render_failure(demographics, ERROR_STATUS) if demographics.failure?

    values = demographics.payload[:values]
    if values.empty? || %w[full_name social_name mother_name].any? { |key| params.key?(key) }
      result = Citizens::CompleteNames.call(verification: verification, full_name: params[:full_name],
                                            social_name: params[:social_name], mother_name: params[:mother_name],
                                            by: Current.user)
      return render_failure(result, ERROR_STATUS) if result.failure?
    end
    return render(json: { error: "already_revoked" }, status: :conflict) unless verification.reload.active?

    citizen.reload
    if values.any?
      saved = save_demographics(citizen, values)
      return render_failure(saved, ERROR_STATUS) if saved.failure?
    end
    patient = Patients::Demographics.patient_of(citizen.reload)
    render json: { citizen: { id: citizen.id, cpf_masked: citizen.cpf_masked, verification_level: citizen.verification_level,
                              names: Citizens::NamesJson.call(citizen) } }.merge(Patients::Demographics.flags(patient))
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

  # D-U1: os campos presentes, validados um a um e na combinação final com o
  # que o paciente (se já existe; o bloco o acha) tem gravado — antes do comando (§13 E12).
  # Módulo 24a (Desvio 8): endereço de paciente com cadastro ativo em domicílio
  # também recusado aqui (address_from_household), antes de gastar o código.
  def parse_demographics
    parsed = Patients::Demographics.parse(params.to_unsafe_h.slice(*Patient::DEMOGRAPHICS))
    return parsed if parsed.failure? || parsed.payload[:values].empty?

    patient = yield
    locked = Patients::Demographics.address_lock(patient, parsed.payload[:values])
    return locked if locked.failure?

    checked = Patients::Demographics.check(Patients::Demographics.current(patient).merge(parsed.payload[:values]))
    checked.failure? ? checked : parsed
  end

  # D-U1: grava no paciente do par validado (Patients::Resolve cria se faltar),
  # numa transação própria depois da do comando (a do Resolve trava CPF → par;
  # juntar com o Verify inverteria a ordem). save! reconfere sob a trava.
  def save_demographics(citizen, values)
    resolved = Patients::Resolve.call(citizen)
    return resolved if resolved.failure?

    patient = resolved.payload[:patient]
    ApplicationRecord.transaction do
      patient.lock!
      saved = Patients::Demographics.save!(patient, values)
      DomainEvents.publish("patient.demographics_updated", patient_id: patient.id, user_id: Current.user.id) if saved.ok?
      saved
    end
  end

  def verification_json(v)
    {
      id: v.id, verified_at: v.verified_at.iso8601, verified_by: v.verified_by_user.email_address,
      phone_masked: CitizenIdentity::Phone.mask(v.citizen.phone), active: v.active?,
      revoked_at: v.revoked_at&.iso8601, revoked_by: v.revoked_by_user&.email_address, revoke_reason: v.revoke_reason
    }
  end
end
