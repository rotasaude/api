# Identidade preservada (ADR 0051; contrato §5, §8; §16 Q24, U4, Q32). Só o
# ouvidor (o técnico e o respondente → 403 missing_role); sem step-up (U4).
#   POST /ombudsman/manifestations/:id/identity { justification } → 200
#     { name, cpf, phone, manifestant_name, manifestant_contact, manifestant_cpf },
#     Cache-Control no-store; uma linha de acesso (scope identity) e um
#     ombudsman.identity_viewed (só ids) por abertura. A anônima → 422 no_identity.
#   POST /ombudsman/manifestations/:id/identity_consent { granted, text } → 201
#     com o detalhe (Q32); evento interno identity_consent_recorded; não revela nada.
# Corpo só com as chaves da rota e nada na query (422 com o nome da chave);
# id malformado ou inexistente → 404.
module Ombudsman
  class IdentitiesController < BaseController
    KEYS = { create: %w[justification], consent: %w[granted text] }.freeze

    before_action :require_ombudsman_role!
    before_action :known_keys!
    before_action :known_manifestation!

    def create
      result = ViewIdentity.call(manifestation_id: params[:id], justification: body_param("justification"), by: Current.user)
      return render_failure(result) if result.failure?

      response.headers["Cache-Control"] = "no-store"
      render json: result.payload.fetch(:identity)
    end

    def consent
      result = RecordIdentityConsent.call(manifestation_id: params[:id], granted: body_param("granted"), text: body_param("text"),
                                          by: Current.user)
      return render_failure(result) if result.failure?

      render_detail(params[:id], status: :created)
    end

    private

    def known_keys!
      return unless query_only!

      unknown = (body.keys - KEYS.fetch(action_name.to_sym)).first
      render_refusal(unknown.to_s[0, KEY_PATH_MAX]) if unknown
    end

    # O id da URL: malformado → 404 antes do comando (que trava pelo id).
    def known_manifestation!
      not_found unless uuid?(params[:id])
    end
  end
end
