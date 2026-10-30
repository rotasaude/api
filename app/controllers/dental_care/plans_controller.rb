# Planos de tratamento odontológico do paciente (ADR 0046; contrato §2). Mais
# novos primeiro; filtro por unidade e situação (ids e enum, nada clínico).
module DentalCare
  class PlansController < BaseController
    def index
      read_patient do |patient|
        limit = page_limit
        next false unless limit

        status = params[:status].presence
        if status && !Catalog::PLAN_STATUSES.include?(status.to_s)
          render_refusal("status")
          next false
        end
        unit_id = params[:health_unit_id].presence
        if unit_id && !uuid?(unit_id)
          render_refusal("health_unit_id")
          next false
        end

        scope = DentalTreatmentPlan.where(patient_id: patient.id)
        scope = scope.where(status: status) if status
        scope = scope.where(health_unit_id: unit_id) if unit_id
        plans = scope.includes(:health_unit, :items).order(created_at: :desc, id: :desc).limit(limit).to_a
        names = Json.procedure_names(plans.flat_map { |plan| plan.items.map(&:procedure_code) })
        render json: { plans: plans.map { |plan| Json.plan(plan, names: names) } }
        true
      end
    end
  end
end
