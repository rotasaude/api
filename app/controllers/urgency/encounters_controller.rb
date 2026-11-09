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
  end
end
