module Lab
  class LookupsController < BaseController
    before_action :provider_param!, only: %i[rejection_reasons candidate_orders exams]
    before_action :collector_only!, only: :candidate_orders

    # Dashboard D14: motivos ATIVOS para o recebimento.
    def rejection_reasons
      render json: { reasons: LabRejectionReason.active.where(exam_provider_id: @provider.id).order(:name).map { |r| Lab::AdminJson.reason(r) } }
    end

    # Dashboard D2: exames do 21a do paciente que cabem numa requisição deste laboratório.
    # B37: sem patient_id não há listagem aberta (422); toda leitura deixa a trilha
    # clinical_record.viewed (access lab_candidates), só ids.
    def candidate_orders
      return render(json: { error: "filter_required" }, status: :unprocessable_entity) if params[:patient_id].blank?

      patient = uuid?(params[:patient_id]) && Patient.find_by(id: params[:patient_id])
      return not_found unless patient

      codes = LabExam.where(exam_provider_id: @provider.id, active: true).where.not(current_version_id: nil).pluck(:sigtap_code)
      orders = ExamOrder.where(patient_id: patient.id, status: %w[awaiting_schedule scheduled], sigtap_code: codes)
                        .where.not(id: LabRequisitionItem.select(:exam_order_id)).includes(:requester_user).order(:created_at)
      grant = ClinicalRecord::Access::Grant.new(kind: :lab_candidates, opening: nil, reason: nil)
      ClinicalRecord::Trail.viewed!(patient: patient, user: Current.user, grant: grant)
      render json: { orders: orders.map do |o|
        { id: o.id, short_code: o.short_code, sigtap_code: o.sigtap_code, label: Exams::Labels.exam(o.sigtap_code, o.sigtap_competence),
          priority: o.priority, status: o.status, requester_name: o.requester_display_name }
      end }
    end

    # Dashboard D3: exames ativos do laboratório (pedido em papel).
    def exams
      exams = LabExam.where(exam_provider_id: @provider.id, active: true).where.not(current_version_id: nil).includes(:current_version).order(:name)
      render json: { exams: exams.map { |e| { sigtap_code: e.sigtap_code, name: e.name, material: e.current_version.material, delivery_days: e.delivery_days } } }
    end

    private

    # L4/B37: quem coleta — lab_staff e o profissional/equipe de UBS que coleta.
    # municipal_admin e lab_releaser (sem esses papéis) não leem a fila do paciente.
    def collector_only!
      forbid unless Lab::Access.staff?(Current.user) || Lab::Access.collecting_unit_ids(Current.user).any?
    end
  end
end
