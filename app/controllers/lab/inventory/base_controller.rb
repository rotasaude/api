# Base das rotas /lab/inventory/* (contrato §5; ADR 0038 §8): municipal_lab
# (herdado) e lab_inventory utilizáveis. Lê e movimenta: membro do
# laboratório (lab_staff, liberador ligado) ou admin; cadastro e ajuste: admin.
# Permissões por laboratório de Lab::ProviderScoped (D10). Item, lote ou
# movimento de outro laboratório responde 404 (C-E25: não revela existência).
module Lab
  module Inventory
    class BaseController < Lab::BaseController
      include Lab::ProviderScoped

      before_action :require_inventory!

      private

      def require_inventory!
        return if Lab::Gate.inventory_usable?(Current.city)

        render json: { error: "feature_disabled", feature: Lab::Gate::INVENTORY_KEY }, status: :forbidden
      end

      def admin? = Lab::Access.admin?(Current.user)

      # O item do parâmetro, se existe e é de um laboratório que a sessão lê.
      def readable_supply(id)
        supply = uuid?(id) && LabSupply.find_by(id: id)
        supply && reader?(supply.exam_provider_id) ? supply : nil
      end
    end
  end
end
