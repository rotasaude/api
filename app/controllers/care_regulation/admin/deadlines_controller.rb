# GET/PATCH /regulation/admin/deadlines (contrato §6): prazo em dias de cada
# cor. Leitura: municipal_admin ou care_regulator; escrita só municipal_admin,
# com step-up.
module CareRegulation
  module Admin
    class DeadlinesController < BaseController
      before_action { forbid unless admin? || regulator? }
      before_action(only: :update) { forbid unless admin? }
      before_action :require_step_up!, only: :update

      def show = render(json: Deadlines.all)

      def update
        result = SaveDeadlines.call(attrs: body, by: Current.user)
        return render_failure(result) if result.failure?

        render json: result.payload.fetch(:deadlines)
      end
    end
  end
end
