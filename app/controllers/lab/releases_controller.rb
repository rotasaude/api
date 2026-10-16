# Fila de liberação (contrato §5; dashboard D9) e o ato de liberar. Leitura
# com valor: clinical_record.viewed (lab_report) por requisição. Só quem é do
# laboratório (lab_staff ou liberador ligado); liberar, só o liberador (Lab::Release).
module Lab
  class ReleasesController < BaseController
    GRANT = ClinicalRecord::Access::Grant.new(kind: :lab_report, opening: nil, reason: nil)
    PRELOAD = [ :patient, { reports: %i[released_by_user pdf_file report_items] },
                { items: [ :lab_sample, { results: :entered_by_user }, { lab_exam_version: :lab_exam } ] } ].freeze

    before_action :provider_param!, only: :index
    before_action :member_of_provider!, only: :index
    before_action :load_requisition, only: %i[show create]

    # Requisições com item digitado fora de laudo à espera de assinatura (B54).
    def index
      ids = LabRequisitionItem.where(status: "typed").where.not(id: Lab::Frozen.item_ids).select(:lab_requisition_id)
      reqs = LabRequisition.where(exam_provider_id: @provider.id, id: ids).order(urgent: :desc, created_at: :asc, id: :asc).limit(100)
                           .includes(*PRELOAD).to_a
      reqs.each { |req| trail(req) }
      render json: { requisitions: Lab::ReleaseJson.requisitions(reqs, viewer: Current.user) }
    end

    def show
      trail(@requisition)
      render json: Lab::ReleaseJson.requisition(@requisition, viewer: Current.user)
    end

    def create
      result = Lab::Release.call(requisition: @requisition, item_ids: params[:item_ids], signature: params[:signature].to_s,
                                 totp: params[:totp], by: Current.user)
      return render_failure(result) if result.failure?

      render json: Lab::Json.report_summary(result.payload[:report], viewer: Current.user), status: :created
    end

    private

    # Fila com valor e nome do paciente: só membro do laboratório (não admin nem UBS).
    def member_of_provider!
      forbid unless Lab::Access.member?(Current.user, @provider.id)
    end

    def load_requisition
      scope = action_name == "show" ? LabRequisition.includes(*PRELOAD) : LabRequisition
      @requisition = uuid?(params[:id]) && scope.find_by(id: params[:id])
      return not_found unless @requisition

      forbid unless Lab::Access.member?(Current.user, @requisition.exam_provider_id)
    end

    def trail(req)
      ClinicalRecord::Trail.viewed!(patient: req.patient, user: Current.user, grant: GRANT, extra: { lab_requisition_id: req.id })
    end
  end
end
