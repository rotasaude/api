# Ações sobre o encontro da urgência (ADR 0050; contrato §6 e §14 Q6, Q7, Q19).
#
# POST /urgency/encounters/:id/call_for_classification { call_location_id? }
# → 200 `{ encounter: <detalhe>, call: { id, kind, ticket, location,
# called_at } | null }` pelo Urgency::CallForClassification (a enfermagem
# 2235 da UPA; não muda o estado). O detalhe sai com o clínico (quem chama
# classifica) e grava a trilha do encontro. O waiting_room_display é lido
# aqui, fora da transação da cidade. Tudo só do corpo; chave desconhecida →
# 422 com o nome da chave.
#
# POST /urgency/encounters/:id/identify { patient_id } | { new_patient,
# duplicates_reviewed? } (contrato §4 e §14 Q5, Q6, Q15, Q17, Q19, Q23) → 200
# `{ encounter: <detalhe>, merged, moved, kept_duplicates }` pelo
# Urgency::Identify, só a recepção (citizen_verifier). O detalhe sai sem o
# clínico para quem não tem vínculo clínico na UPA (Q19); `moved` e
# `kept_duplicates` são as contagens da fusão (0 com paciente novo). Duplicado
# suspeito → 409 com `candidates`.
#
# POST /urgency/encounters/:id/outcome { kind, destination?, vacancy_request?,
# return_guidance?: { days, reason }, reason? } (contrato §7 e §14 Q10, Q15,
# Q19, Q25) → 201 `{ encounter: <detalhe>, attendance: { id, status, outcome } }`
# pelo Urgency::RecordOutcome. A equipe da contrarreferência (só na alta para
# a UBS) é lida aqui, fora da transação da cidade. O detalhe sai sem o clínico
# para quem não tem vínculo clínico na UPA (a recepção, Q19).
module Urgency
  class EncountersController < BaseController
    CALL_KEYS = %w[call_location_id].freeze
    IDENTIFY_KEYS = %w[patient_id new_patient duplicates_reviewed].freeze

    def call_for_classification
      return unless query_only!

      unknown = (body.keys - CALL_KEYS).first
      return render_refusal(unknown.to_s[0, KEY_PATH_MAX]) if unknown

      encounter = find_encounter(params[:id])
      return unless encounter

      result = CallForClassification.call(encounter: encounter, call_location_id: body_param("call_location_id"), by: Current.user,
                                          waiting_room: WaitingRoom::Gate.usable?(Current.city))
      return render_failure(result) if result.failure?

      clinical = Access.clinical_link(Current.user, encounter.attendance.health_unit_id).present?
      render_encounter(encounter.reload, clinical: clinical, call: Attendances::CallRecord.json(result.payload[:call]))
    end

    def identify
      return unless query_only!
      return unless require_reception!

      unknown = (body.keys - IDENTIFY_KEYS).first
      return render_refusal(unknown.to_s[0, KEY_PATH_MAX]) if unknown

      encounter = find_encounter(params[:id])
      return unless encounter

      result = Identify.call(encounter: encounter, patient_id: body_param("patient_id"), new_patient: body_param("new_patient"),
                             duplicates_reviewed: body_param("duplicates_reviewed"), by: Current.user)
      return render_failure(result) if result.failure?

      clinical = Access.clinical_link(Current.user, encounter.attendance.health_unit_id).present?
      render_encounter(UrgencyEncounter.find(encounter.id), clinical: clinical, merged: result.payload[:merged_from_id].present?,
                                                            moved: result.payload[:moved].values.sum,
                                                            kept_duplicates: result.payload[:kept_duplicates].values.sum)
    end

    def outcome
      return unless query_only!

      encounter = find_encounter(params[:id])
      return unless encounter

      result = RecordOutcome.call(encounter: encounter, attrs: body, by: Current.user, team: counter_referral_team(encounter))
      return render_failure(result) if result.failure?

      attendance = result.payload[:attendance]
      clinical = Access.clinical_link(Current.user, attendance.health_unit_id).present?
      render_encounter(UrgencyEncounter.find(encounter.id), clinical: clinical, status: :created,
                                                            attendance: { id: attendance.id, status: attendance.status,
                                                                          outcome: attendance.outcome })
    end

    private

    # A equipe de referência do paciente (regra do 23, CareLines::TeamPopulation),
    # só para a alta com retorno à UBS; sem equipe → nil (o desfecho grava os
    # dois nulos). O provisório não tem equipe (e a alta dele é recusada).
    def counter_referral_team(encounter)
      return nil unless body["kind"] == "discharged_to_primary_care"

      patient_id = encounter.attendance.patient_id
      team_id = CareLines::TeamPopulation.patient_teams([ patient_id ])[patient_id]
      team_id && HealthTeam.find_by(id: team_id)
    end
  end
end
