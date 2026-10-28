# GET/POST/DELETE /regulation/admin/nurse_items (contrato §6): o que o
# enfermeiro pode pedir. Corpo `{ target_type, target_code }`. Leitura:
# municipal_admin ou care_regulator; escrita só municipal_admin, com step-up.
module CareRegulation
  module Admin
    class NurseItemsController < BaseController
      before_action { forbid unless admin? || regulator? }
      before_action(only: %i[create destroy]) { forbid unless admin? }
      before_action :require_step_up!, only: %i[create destroy]

      def index = render(json: { items: NurseItems.list })

      def create
        result = NurseItems.add(target_type: body_param("target_type"), target_code: body_param("target_code"), by: Current.user)
        return render_failure(result) if result.failure?

        target = result.payload.fetch(:target)
        render json: { target_type: target.type, target_code: target.code, name: target.name }, status: :created
      end

      def destroy
        result = NurseItems.remove(target_type: body_param("target_type"), target_code: body_param("target_code"), by: Current.user)
        return render_failure(result) if result.failure?

        head :no_content
      end
    end
  end
end
