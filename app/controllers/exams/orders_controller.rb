# GET/POST /exams/orders e GET /exams/orders/:id (contrato §3; D2, D5, D6).
module Exams
  class OrdersController < BaseController
    AUTHOR_GRANT = Exams::Access::Grant.new(view: :clinical, kind: :author, opening: nil)

    def index
      scope, view = scope_and_view
      return if performed?

      page = Exams::OrderQuery.call(scope, params)
      # A trilha só depois de a consulta valer: 422 de filtro/cursor não grava.
      @trail&.call
      page[:orders].each { |o| Exams::Trail.viewed!(order: o, user: Current.user, grant: AUTHOR_GRANT) } if @trail_each_order
      render json: { orders: page[:orders].map { |o| Exams::Json.order(o, view: view, user: Current.user, events: false) },
                     next_before: page[:next_before] }
    rescue Exams::OrderQuery::InvalidFilter
      render json: { error: "invalid_filter" }, status: :unprocessable_entity
    rescue Exams::Cursor::Invalid
      render json: { error: "invalid_cursor" }, status: :unprocessable_entity
    end

    def show
      order = uuid?(params[:id]) && ExamOrder.find_by(id: params[:id])
      return not_found unless order

      grant = Exams::Access.for_order(user: Current.user, order: order)
      return not_found unless grant

      Exams::Trail.viewed!(order: order, user: Current.user, grant: grant)
      render json: Exams::Json.order(order, view: grant.view, user: Current.user,
                                     cid10: Exams::Access.cid10_reader?(Current.user))
    end

    # Tudo numa transação: a recusa depois do Patients::Resolve (catálogo,
    # guia) desfaz o paciente criado/ligado e os eventos dele.
    def create
      result = nil
      ApplicationRecord.transaction do
        input = Exams::GuideInput.call(params, user: Current.user)
        result = input.failure? ? input : open_guide(input.payload[:attrs])
        raise ActiveRecord::Rollback if result.failure?
      end
      return render_failure(result) if result.failure?

      render json: Exams::Json.order(result.payload[:order], view: :administrative, user: Current.user), status: :created
    end

    private

    def open_guide(attrs)
      file = Exams::Files.claim!(file_id: params[:guide_upload_id], user: Current.user)
      return Result.fail(:guide_missing) unless file

      Exams::Open.call(**attrs, origin: "reception_guide", guide_file: file, created_by: Current.user)
    end

    # [scope, view]; senão a resposta de erro já saiu. Recortes: consulta
    # (dashboard D6), paciente, requester=me, unidade, ou — só admin e
    # regulador — atrasos da cidade inteira (dashboard D15).
    def scope_and_view
      if params[:consultation_id].present?
        consultation = uuid?(params[:consultation_id]) && Consultation.find_by(id: params[:consultation_id])
        return not_found unless consultation

        grant = ClinicalRecord::Access.for_consultation(user: Current.user, consultation: consultation)
        return forbid(grant.reason.to_s) unless grant.allowed?

        @trail = -> { ClinicalRecord::Trail.viewed!(patient: consultation.patient, user: Current.user, grant: grant, consultation_id: consultation.id) }
        [ ExamOrder.joins(:consultation_exam_request).where(consultation_exam_requests: { consultation_id: consultation.id }), :clinical ]
      elsif params[:patient_id].present?
        patient = uuid?(params[:patient_id]) && Patient.find_by(id: params[:patient_id])
        return not_found unless patient

        grant = ClinicalRecord::Access.call(user: Current.user, patient: patient)
        return forbid(grant.reason.to_s) unless grant.allowed?

        @trail = -> { ClinicalRecord::Trail.viewed!(patient: patient, user: Current.user, grant: grant) }
        [ ExamOrder.where(patient_id: patient.id), :clinical ]
      elsif params[:requester] == "me"
        return forbid("missing_role") unless Current.user.has_role?("health_professional")

        # Pedidos de vários pacientes na visão clínica: trilha por exame.
        @trail_each_order = true
        [ ExamOrder.where(requester_user_id: Current.user.id), :clinical ]
      elsif params[:unit_id].present?
        return forbid("not_unit_staff") unless uuid?(params[:unit_id]) && Exams::Access.unit_staff?(Current.user, params[:unit_id])

        [ ExamOrder.where(unit_id: params[:unit_id]), :administrative ]
      elsif params[:overdue] == "true" && Exams::Access.regulator?(Current.user)
        [ ExamOrder.all, :administrative ]
      else
        render json: { error: "filter_required" }, status: :unprocessable_entity
      end
    end
  end
end
