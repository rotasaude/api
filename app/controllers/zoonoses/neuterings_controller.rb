# POST /zoonoses/neuterings (módulo 35b, ADR 0054; contrato §7, §10, Q30): a
# castração, só da veterinária (Zoonoses::RecordNeutering → 403
# veterinarian_required), depois do team? (403 missing_role). → 201 com
# `{ veterinarian: { name, crmv } }` do perfil profissional. Só acréscimo: não
# há edição nem exclusão. Query → 422 invalid_request.
module Zoonoses
  class NeuteringsController < BaseController
    before_action :team!
    before_action { query_only! }

    def create
      result = RecordNeutering.call(params: body, by: Current.user)
      return render_failure(result) if result.failure?

      render json: Json.neutering_record(result.payload.fetch(:neutering)), status: :created
    end
  end
end
