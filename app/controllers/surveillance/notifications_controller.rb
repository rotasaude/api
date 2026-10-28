# POST /surveillance/notifications (contrato §4): o ramo da consulta
# ({ consultation_id, disease_code, symptoms_on? }, health_professional). Dado
# do paciente e da doença só do corpo JSON. 201 com a forma nominal completa e
# uma trilha por pessoa (Surveillance::Trail). O 409 already_notified só traz
# o id da notificação existente para quem tem o papel `surveillance`.
module Surveillance
  class NotificationsController < BaseController
    before_action :require_surveillance_consultation!, only: :create
    before_action(only: :create) { forbid unless Current.user.has_role?("health_professional") }

    def create
      consultation_id = body_param("consultation_id")
      return render_error("invalid_request") unless consultation_id.is_a?(String)

      consultation = uuid?(consultation_id) && Consultation.where.not(status: "discarded").find_by(id: consultation_id)
      return not_found unless consultation

      result = NotifyFromConsultation.call(consultation: consultation, disease_code: body_param("disease_code"),
                                           symptoms_on: body_param("symptoms_on"), by: Current.user)
      return render_notify_failure(result) if result.failure?

      notification = result.payload.fetch(:notification)
      Trail.person_viewed!(user: Current.user, patient_id: notification.patient_id)
      render json: Json.notification(notification), status: :created
    end

    private

    def render_notify_failure(result)
      return render(json: { error: "missing_role" }, status: :forbidden) if result.reason == :missing_role
      return render_error("already_notified", :conflict) if result.reason == :already_notified && !surveillance?

      render_failure(result)
    end
  end
end
