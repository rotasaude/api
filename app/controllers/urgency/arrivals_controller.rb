# POST /urgency/arrivals { health_unit_id, patient_id? | new_patient? |
# unidentified?: { description }, duplicates_reviewed? } (contrato §4, §14
# Q4, Q15, Q23): a chegada na UPA pelo Urgency::Arrive. → 201 `{
# attendance_id, encounter_id, ticket | null, patient: <patient-ref> }` (sem a
# descrição: ela só sai no detalhe). Duplicado suspeito do paciente novo → 409
# duplicate_suspected com `candidates`; reenviar com duplicates_reviewed: true.
# Só a recepção (citizen_verifier). O waiting_room_display é lido aqui, fora
# da transação da cidade. Tudo só do corpo: nada na query, e chave
# desconhecida no corpo → 422 com o nome da chave (P23 do 31).
module Urgency
  class ArrivalsController < BaseController
    ALLOWED = %w[health_unit_id patient_id new_patient unidentified duplicates_reviewed].freeze

    before_action :require_reception!

    def create
      return unless query_only!

      unknown = (body.keys - ALLOWED).first
      return render_refusal(unknown.to_s[0, KEY_PATH_MAX]) if unknown

      result = Arrive.call(health_unit_id: body_param("health_unit_id"), patient_id: body_param("patient_id"),
                           new_patient: body_param("new_patient"), unidentified: body_param("unidentified"),
                           duplicates_reviewed: body_param("duplicates_reviewed"),
                           by: Current.user, waiting_room: WaitingRoom::Gate.usable?(Current.city))
      return render_failure(result) if result.failure?

      render json: Json.arrival(**result.payload), status: :created
    end
  end
end
