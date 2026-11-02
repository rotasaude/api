# POST /vaccination/rooms/:room_id/transcriptions (contrato §5; §15 V14, V19):
#   { patient_id, items: [ { immunobiological_code, dose_code, applied_on, lot_number?, manufacturer_name?, place? } ],
#     close_check } → 201 { immunizations: [<immunization>], card: <card> }
# Vacinador ou responsável da sala (fora da equipe → 403; sem vínculo de
# vacinador na unidade → 403). Recusas 422 com todos os `problems`
# (`items[i].<campo>`). Leitura nominal: uma trilha pela pessoa (o comando
# grava). Tudo do paciente só no corpo (query → 422).
module Vaccination
  class TranscriptionsController < BaseController
    def create
      room = member_room or return
      return unless query_only!

      patient = body_patient or return
      result = RecordTranscription.call(room: room, patient: patient, items: body_param("items"),
                                        close_check: request.request_parameters["close_check"], by: Current.user)
      return render_transcription_failure(result) if result.failure?

      doses = result.payload.fetch(:immunizations)
      render json: { immunizations: Json.immunizations(doses, rnds_usable: Rnds::Gate.usable?(Current.city), viewer: Current.user),
                     card: result.payload.fetch(:card) },
             status: :created
    end

    private

    def render_transcription_failure(result)
      return forbid if result.reason == :missing_role

      problems = result.details.fetch(:problems)
      render json: { error: problems.first[:error], path: problems.first[:path], problems: problems }, status: :unprocessable_entity
    end
  end
end
