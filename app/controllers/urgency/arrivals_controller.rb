# POST /urgency/arrivals { health_unit_id, patient_id? | new_patient? |
# unidentified?: { description } } (contrato §4, §14 Q4, Q15): a chegada na
# UPA pelo Urgency::Arrive. → 201 `{ attendance_id, encounter_id, ticket |
# null, patient: <patient-ref> }` (sem a descrição: ela só sai no detalhe).
# Só a recepção (citizen_verifier). O waiting_room_display é lido aqui, fora
# da transação da cidade. Tudo só do corpo: nada na query.
module Urgency
  class ArrivalsController < BaseController
    before_action :require_reception!

    def create
      return unless query_only!

      result = Arrive.call(health_unit_id: body_param("health_unit_id"), patient_id: body_param("patient_id"),
                           new_patient: body_param("new_patient"), unidentified: body_param("unidentified"),
                           by: Current.user, waiting_room: WaitingRoom::Gate.usable?(Current.city))
      return render_failure(result) if result.failure?

      render json: Json.arrival(**result.payload), status: :created
    end
  end
end
