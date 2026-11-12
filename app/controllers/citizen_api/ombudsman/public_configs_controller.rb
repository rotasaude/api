#   GET /citizen/ombudsman/public_config
#       → { anonymous_web: bool, units: [{ id, name }] }
# Configuração pública da ouvidoria (ADR 0051; contrato §4; §16 Q1, Q20, Q41):
# se a denúncia anônima sem login está utilizável e as unidades ativas por
# nome, CAPS inclusive. Sem `ombudsman` → 403 feature_disabled. Rota pública:
# não lê nem cria `citizen_session` e não grava cookie. Nada de dado na URL:
# chave na query → 422 com o nome.
module CitizenApi
  module Ombudsman
    class PublicConfigsController < CitizenApi::BaseController
      include ::OmbudsmanGate

      wrap_parameters false
      allow_anonymous_citizen

      KEY_PATH_MAX = 64

      before_action :require_ombudsman!
      before_action :query_only!

      def show
        render json: {
          anonymous_web: ::Ombudsman::AnonymousGate.usable?(Current.city),
          units: HealthUnit.active_units.map { |unit| { id: unit.id, name: unit.name } }
        }
      end

      private

      def query_only!
        unknown = request.query_parameters.keys.first
        return unless unknown

        path = unknown.to_s[0, KEY_PATH_MAX]
        render json: { error: "invalid_request", path: path, problems: [ { error: "invalid_request", path: path } ] },
               status: :unprocessable_entity
      end
    end
  end
end
