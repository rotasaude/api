# Ações sobre o encontro da urgência (ADR 0050; contrato §6 e §14 Q6, Q7, Q19).
#
# POST /urgency/encounters/:id/call_for_classification { call_location_id? }
# → 200 `{ encounter: <detalhe>, call: { id, kind, ticket, location,
# called_at } | null }` pelo Urgency::CallForClassification (a enfermagem
# 2235 da UPA; não muda o estado). O detalhe sai com o clínico (quem chama
# classifica) e grava a trilha do encontro. O waiting_room_display é lido
# aqui, fora da transação da cidade. Tudo só do corpo; chave desconhecida →
# 422 com o nome da chave.
module Urgency
  class EncountersController < BaseController
    CALL_KEYS = %w[call_location_id].freeze

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
  end
end
