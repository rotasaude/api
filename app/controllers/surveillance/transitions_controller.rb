# Andamento da notificação (contrato §5; papel `surveillance`):
#   POST /surveillance/notifications/:id/transition  { to, classification?, official_number?, reason?, version }
#   POST /surveillance/notifications/:id/dismiss     { reason, version }   (só `possible`)
# Tudo só do corpo JSON. 200 com a forma nominal completa e a trilha por
# pessoa (como o PATCH da ficha). Motivo, classificação e número oficial nunca
# em log, evento nem erro.
module Surveillance
  class TransitionsController < BaseController
    before_action { forbid unless surveillance? }
    before_action :load_notification
    before_action :read_version

    def transition
      to = body_param("to")
      return render_error("invalid_request") unless to.is_a?(String)

      respond Transition.call(notification: @notification, to: to, version: @version, by: Current.user,
                              classification: body_param("classification"), official_number: body_param("official_number"),
                              reason: body_param("reason"))
    end

    def dismiss
      respond Dismiss.call(notification: @notification, reason: body_param("reason"), version: @version, by: Current.user)
    end

    private

    def load_notification
      return unless query_only!

      @notification = uuid?(params[:id]) ? DiseaseNotification.find_by(id: params[:id]) : nil
      not_found unless @notification
    end

    def read_version
      @version = body_param("version")
      render_error("invalid_request") unless @version.is_a?(Integer)
    end

    def respond(result)
      return render_failure(result) if result.failure?

      saved = result.payload.fetch(:notification)
      Trail.person_viewed!(user: Current.user, patient_id: saved.patient_id)
      render json: Json.notification(saved)
    end
  end
end
