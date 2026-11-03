# Dose aplicada na sala (contrato §2, §5; §15 V5, V6, V10):
#   POST /vaccination/rooms/:room_id/immunizations  { patient_id, immunobiological_code, dose_code, strategy, care_group,
#        route, site, maternal_condition?, applied_at, lot_id, vial_id?, campaign_id?, override_reason? } → 201 <immunization>
#   GET  /vaccination/immunizations/:id → <immunization>
#   POST /vaccination/immunizations/:id/cancel  { reason, replacement?: {forma do POST, sem patient_id} }
#        → 200 { cancelled: <immunization>, replacement: <immunization>|null }
# Registrar: vacinador ou responsável da sala (fora da equipe → 403). Recusas
# 422 com todos os `problems` de uma vez; os avisos (intervalo, idade) com
# `overridable: true` até vir `override_reason`.
# Ler (V10): a equipe da sala da dose, ou quem lê a linha do tempo do
# paciente (patient_timeline ligado e a regra do 19a/20 sobre a pessoa:
# contexto ou abertura justificada); fora disso → 404. Ambas nominais: uma
# trilha clinical_record.viewed (access "vaccination"), com o reason_code da
# abertura justificada (nulo na leitura pela equipe). Dado do paciente só no
# corpo (query → 422).
# Cancelar (Task 9; §15 V6, V7): step-up (401 mfa_required); o autor ou o
# `room_lead` da sala (da equipe sem ser um dos dois → 403
# cancel_not_allowed; fora da equipe e não autor → 404); já cancelada → 409
# already_cancelled; motivo 10..500 → senão 422 invalid_reason; a substituta
# recusada não cancela nada e volta em `problems` com path `replacement.*`.
# A trilha da pessoa é gravada pelo comando.
# ESAVI (Task 19; Desvio 17; §15 V12): POST /vaccination/immunizations/:id/esavi
#   → 201 { notification_id } | 200 { notification_id, existing: true } (já há uma
#   esavi aberta para o paciente; idempotente). `surveillance` desligado → 403
#   feature_disabled (feature "surveillance"; lido antes da transação). Só a
#   equipe da sala da dose ou papel `surveillance` (qualquer dose da cidade, como
#   quem notifica no 25); outro escopo (inclusive transcrição sem sala) → 404;
#   dose cancelada → 409 immunization_cancelled. Trilha da pessoa (access
#   "surveillance", como a criação manual do 25) só na criação.
module Vaccination
  class ImmunizationsController < BaseController
    include ::SurveillanceGate

    before_action :require_step_up!, only: :cancel
    before_action :require_surveillance!, only: :esavi

    def create
      room = member_room or return
      return unless query_only!

      patient = body_patient or return
      rnds_enabled = Rnds::Gate.enabled?(Current.city)
      result = RecordImmunization.call(room: room, patient: patient, attrs: body.except("patient_id"), by: Current.user)
      return render_dose_failure(result) if result.failure?

      dose = result.payload[:immunization]
      render json: Json.immunization(dose, rnds_enabled: rnds_enabled, viewer: Current.user), status: :created
    end

    def show
      return unless query_only!

      dose = uuid?(params[:id]) ? Immunization.includes(:patient, vaccine_room: :health_unit).find_by(id: params[:id]) : nil
      grant = dose && access_grant(dose)
      return not_found unless grant

      Trail.person_viewed!(user: Current.user, patient_id: dose.patient_id, reason_code: grant.opening&.reason_code)
      render json: Json.immunization(dose, rnds_enabled: Rnds::Gate.enabled?(Current.city), viewer: Current.user)
    end

    def cancel
      return unless query_only!

      dose = uuid?(params[:id]) ? Immunization.includes(vaccine_room: :health_unit).find_by(id: params[:id]) : nil
      return not_found unless dose && (dose.vaccinator_user_id == Current.user.id ||
                                       (dose.vaccine_room && Access.room_roles(user: Current.user, room: dose.vaccine_room).any?))

      rnds_enabled = Rnds::Gate.enabled?(Current.city)
      result = CancelImmunization.call(immunization: dose, reason: body_param("reason"), replacement: body_param("replacement"), by: Current.user)
      return render_cancel_failure(result) if result.failure?

      cancelled, substitute = Immunization.includes(:replacement).find(result.payload[:cancelled].id), result.payload[:replacement]
      render json: { cancelled: dose_json(cancelled, rnds_enabled), replacement: substitute && dose_json(substitute, rnds_enabled) }
    end

    def esavi
      return unless query_only!

      dose = uuid?(params[:id]) ? Immunization.includes(vaccine_room: :health_unit).find_by(id: params[:id]) : nil
      return not_found unless dose && (Current.user.has_role?("surveillance") ||
                                       (dose.vaccine_room && Access.room_roles(user: Current.user, room: dose.vaccine_room).any?))

      result = NotifyEsavi.call(immunization: dose, by: Current.user, now: Time.current)
      return render_error(result.reason, result.reason == :immunization_cancelled ? :conflict : :unprocessable_entity) if result.failure?

      notification_id = result.payload.fetch(:notification_id)
      return render json: { notification_id: notification_id, existing: true } unless result.payload.fetch(:created)

      Surveillance::Trail.person_viewed!(user: Current.user, patient_id: dose.patient_id)
      render json: { notification_id: notification_id }, status: :created
    end

    private

    def dose_json(dose, rnds_enabled)
      Json.immunization(dose, rnds_enabled: rnds_enabled, viewer: Current.user)
    end

    def render_cancel_failure(result)
      case result.reason
      when :invalid_reason then render_refusal("reason", "invalid_reason")
      when :cancel_not_allowed, :missing_role then forbid(result.reason.to_s)
      when :already_cancelled then render_error(:already_cancelled, :conflict)
      when :invalid then render_dose_failure(result)
      else render_failure(result)
      end
    end

    TEAM_GRANT = ClinicalRecord::Access::Grant.new(kind: :vaccine_room, opening: nil, reason: nil)

    # Grant da leitura (equipe da sala: sem abertura; linha do tempo: o grant
    # do 19a/20, com a abertura justificada quando houver) ou nil (→ 404).
    def access_grant(dose)
      return TEAM_GRANT if dose.vaccine_room && Access.room_roles(user: Current.user, room: dose.vaccine_room).any?
      return nil unless Timeline::Gate.enabled?(Current.city)

      grant = ClinicalRecord::Access.for_person(user: Current.user, person: Timeline::Person.for_patient(dose.patient))
      grant.allowed? ? grant : nil
    end

    def render_dose_failure(result)
      return forbid if result.reason == :missing_role

      problems = result.details.fetch(:problems)
      render json: { error: problems.first[:error], path: problems.first[:path], problems: problems }, status: :unprocessable_entity
    end
  end
end
