# A fila da vigilância (contrato §5; papel `surveillance`):
#   GET   /surveillance/notifications        a fila, com cursor (uma trilha por consulta)
#   GET   /surveillance/notifications/count   contadores (sem trilha)
#   GET   /surveillance/notifications/:id     o detalhe (trilha por pessoa)
#   PATCH /surveillance/notifications/:id     a ficha inteira, { form, version }
# E POST /surveillance/notifications. Dois ramos, escolhidos por `consultation_id`
# no corpo:
#   - com ele (contrato §4): a consulta ({ consultation_id, disease_code,
#     symptoms_on? }, health_professional);
#   - sem ele (contrato §5, K4): a notificação manual da vigilância
#     (Surveillance::CreateManual; papel `surveillance`).
# Dado do paciente e da doença só do corpo JSON. 201 com a forma nominal
# completa e uma trilha por pessoa (Surveillance::Trail). O 409
# already_notified só traz o id da notificação existente para quem tem o
# papel `surveillance` (no ramo manual, sempre).
module Surveillance
  class NotificationsController < BaseController
    QUEUE_PARAMS = (Queue::FILTERS + %w[before limit]).freeze

    before_action(only: %i[index show update count]) { forbid unless surveillance? }
    before_action :require_surveillance_consultation!, only: :create, if: :consultation_branch?
    before_action(only: :create, if: :consultation_branch?) { forbid unless Current.user.has_role?("health_professional") }
    before_action(only: :create, unless: :consultation_branch?) { forbid unless surveillance? }

    def index
      return unless query_only!(*QUEUE_PARAMS)

      limit = page_limit
      return unless limit

      query = request.query_parameters
      result = Queue.call(filters: query.slice(*Queue::FILTERS), limit: limit, before: query["before"])
      return render_failure(result) if result.failure?

      rows = result.payload.fetch(:rows)
      Trail.listed!(user: Current.user, notification_ids: rows.map(&:id)) if rows.any?
      diseases = Diseases.all.index_by(&:code)
      render json: { notifications: rows.map { |n| Json.notification(n, full: false, diseases: diseases) },
                     next_before: result.payload.fetch(:next_before) }
    end

    def count
      render json: Queue.counts
    end

    def show
      notification = find_notification
      return not_found unless notification

      Trail.person_viewed!(user: Current.user, patient_id: notification.patient_id)
      render json: Json.notification(notification)
    end

    # A ficha inteira e a versão que o cliente leu, só do corpo.
    def update
      return unless query_only!

      notification = find_notification
      return not_found unless notification

      version = body_param("version")
      return render_error("invalid_request") unless version.is_a?(Integer)

      result = SaveForm.call(notification: notification, form: body_param("form"), version: version, by: Current.user)
      return render_failure(result) if result.failure?

      saved = result.payload.fetch(:notification)
      Trail.person_viewed!(user: Current.user, patient_id: saved.patient_id)
      render json: Json.notification(saved)
    end

    def create
      consultation_branch? ? create_from_consultation : create_manual
    end

    private

    def find_notification = uuid?(params[:id]) ? DiseaseNotification.find_by(id: params[:id]) : nil

    def consultation_branch? = !body_param("consultation_id").nil?

    def create_manual
      result = CreateManual.call(params: body, by: Current.user)
      return render_failure(result) if result.failure?

      notification = result.payload.fetch(:notification)
      Trail.person_viewed!(user: Current.user, patient_id: notification.patient_id)
      render json: Json.notification(notification), status: :created
    end

    def create_from_consultation
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

    def render_notify_failure(result)
      return render(json: { error: "missing_role" }, status: :forbidden) if result.reason == :missing_role
      return render_error("already_notified", :conflict) if result.reason == :already_notified && !surveillance?

      render_failure(result)
    end
  end
end
