# PTS da matrícula (ADR 0049; contrato §4, P4, P12, P13, P16):
#   POST /psychosocial/enrollments/:id/care_plans  → 201 <versão N+1>, sem trilha (quem grava digitou)
#   GET  /psychosocial/enrollments/:id/care_plans  { items } da mais nova para a mais antiga, com trilha (`care_plans`)
#   GET  /psychosocial/care_plans/due?health_unit_id  { items: [ { enrollment_id, patient, review_on | null } ] }:
#        revisões vencidas (o técnico de referência vê as suas; a coordenação, todas), sem trilha
# Matrícula de outro CAPS (ou de CAPS onde quem pede não está lotado) → 404.
# Texto clínico só no corpo; ids na URL.
module Psychosocial
  class CarePlansController < BaseController
    before_action :load_enrollment, only: %i[index create]

    def index
      plans = @enrollment.psychosocial_care_plans.reorder(version: :desc).includes(created_by_user: :professional).to_a
      cbos = Access.cbos(plans.map(&:created_by_user_id), @enrollment.health_unit_id)
      Trail.viewed!(patient: @enrollment.patient_id, user: Current.user, resource: "care_plans")
      render json: { items: plans.map { |plan| Json.care_plan(plan, cbos: cbos) } }
    end

    def create
      result = SaveCarePlan.call(enrollment: @enrollment, attrs: body, by: Current.user)
      return render_failure(result) if result.failure?

      plan = result.payload.fetch(:care_plan)
      render json: Json.care_plan(plan, cbos: Access.cbos([ plan.created_by_user_id ], @enrollment.health_unit_id)), status: :created
    end

    def due
      return unless query_only!("health_unit_id")

      unit = staff_unit!(request.query_parameters["health_unit_id"])
      return unless unit

      rows = CarePlanReview.due(unit: unit, today: Time.zone.today, user: Access.lead?(Current.user) ? nil : Current.user)
      render json: { items: rows.map { |enrollment, review_on| Json.care_plan_due(enrollment, review_on) } }
    end
  end
end
