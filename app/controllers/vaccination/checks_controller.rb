# POST /vaccination/rooms/:room_id/checks (contrato §5; Desvio 10):
# `{ patient_id, mode: "confirmed_complete" }` → a caderneta conferida. Outro
# modo → 422 (path mode); `transcribed` é da transcrição e born_after_go_live
# do sistema. Vacinador ou responsável da sala; fora da equipe → 403;
# paciente inexistente → 404. Uma trilha pela pessoa (no comando).
module Vaccination
  class ChecksController < BaseController
    def create
      room = member_room or return
      return unless query_only!
      return render_refusal("mode") unless body_param("mode") == RecordCheck::MODE

      patient = body_patient or return
      today = Time.zone.today
      result = RecordCheck.call(room: room, patient: patient, mode: body_param("mode"), by: Current.user, today: today)
      return render_failure(result) if result.failure?

      render json: Card.call(patient: patient, today: today, rnds_enabled: Rnds::Gate.enabled?(Current.city), viewer: Current.user)
    end
  end
end
