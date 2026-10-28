# /attendance/consultations/:id/regulation_requests (contrato §3; plano Task 4):
# o pedido de regulação em rascunho na consulta. Só a autora (rascunho ou
# finalizada, para o adendo); profissional de saúde. A lista traz rascunhos e
# promovidos, sem trilha (a consulta já deixa). Dado do paciente só do corpo.
module CareRegulation
  class ConsultationRequestsController < BaseController
    before_action { forbid unless Current.user.has_role?("health_professional") }
    before_action :load_consultation
    before_action :load_request, only: %i[update destroy]

    PRELOAD = [ :patient, { requester_user: :professional }, :requester_unit,
                { authorizations: [ { care_offer: :care_provider }, { authorized_by_user: :professional } ] },
                { events: { by_user: :professional } } ].freeze

    def index
      return forbid("not_author") unless @consultation.author_user_id == Current.user.id

      today = Time.zone.today
      rows = RegulationRequest.where(consultation_id: @consultation.id).includes(*PRELOAD).order(:created_at, :id)
      render json: { requests: rows.map { |row| Json.request(row, today: today) } }
    end

    def create
      result = SaveDraft.call(consultation: @consultation, attrs: body, by: Current.user)
      return render_failure(result) if result.failure?

      render json: Json.request(result.payload.fetch(:request)), status: :created
    end

    def update
      result = SaveDraft.call(consultation: @consultation, attrs: body, by: Current.user, request: @request_row)
      return render_failure(result) if result.failure?

      render json: Json.request(result.payload.fetch(:request)), status: :ok
    end

    def destroy
      result = DiscardDraft.call(request: @request_row, by: Current.user)
      return render_failure(result) if result.failure?

      head :no_content
    end

    private

    def load_consultation
      @consultation = uuid?(params[:id]) && Consultation.where.not(status: "discarded").find_by(id: params[:id])
      not_found unless @consultation
    end

    def load_request
      @request_row = uuid?(params[:rid]) && RegulationRequest.find_by(id: params[:rid], consultation_id: @consultation.id)
      not_found unless @request_row
    end
  end
end
