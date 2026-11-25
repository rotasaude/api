# Base das rotas do envio à BNAFAR que exigem o interruptor `bnafar` (módulo
# 27b; contrato §6; Valor 9): situação, remessas, registros (reenvio e
# correção). Sem o `bnafar` utilizável → 403 feature_disabled com a `feature`
# `bnafar`. As pendências e os domínios NÃO herdam desta classe: pedem só o
# estoque do domínio (Q19, Q22). Dentro de `Pharmacy::` o domínio é sempre
# `::Bnafar::…` (esta pasta cria o módulo Pharmacy::Bnafar).
module Pharmacy
  module Bnafar
    class BaseController < ::Pharmacy::BaseController
      include ::BnafarGate
      include ::BnafarReader

      skip_before_action :require_pharmacy!
      before_action :require_bnafar!

      private

      # O ambiente em uso (lido na conexão da cidade).
      def environment = (@environment ||= ::Bnafar::Environment.current)

      def submission_param
        uuid?(params[:id]) ? BnafarSubmission.find_by(id: params[:id], environment: environment) : nil
      end

      # `YYYY-MM-DD` → Date; senão nil.
      def date_param(key)
        raw = params[key]
        return nil unless raw.is_a?(String) && raw.match?(/\A\d{4}-\d{2}-\d{2}\z/)

        Date.iso8601(raw)
      rescue Date::Error
        nil
      end
    end
  end
end
