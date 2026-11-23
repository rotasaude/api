# POST /zoonoses/euthanasias (módulo 35b, ADR 0054; contrato §7, §10, Q30): a
# eutanásia, só da veterinária (Zoonoses::RecordEuthanasia → 403
# veterinarian_required), com step-up (401 mfa_required), depois do team?
# (403 missing_role). → 201 com `{ veterinarian: { name, crmv } }` do perfil
# profissional, nunca a nota. O registro é imutável: não há rota de leitura
# avulsa, edição nem exclusão (404). Query → 422 invalid_request.
module Zoonoses
  class EuthanasiasController < BaseController
    before_action :team!
    before_action { query_only! }
    before_action :require_step_up!

    def create
      result = RecordEuthanasia.call(params: body, by: Current.user)
      return render_failure(result) if result.failure?

      render json: Json.euthanasia_record(result.payload.fetch(:euthanasia)), status: :created
    end
  end
end
