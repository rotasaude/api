# GET/POST/PATCH /pharmacy/admin/locations[/:id] (contrato §3): locais de
# estoque. Só municipal_admin; escrita com step-up. Nunca se apaga: desativa-se
# (`active: false`), e só sem saldo. Escritas devolvem o objeto, sem envelope.
# Só os locais da farmácia (central e unit) e o da vigilância ambiental
# (vector_control, módulo 35a, A-12): a rede de frio e a sala de vacina
# (módulo 29) se administram por /vaccination/admin — fora da lista, e 404 por id.
# Módulo 35a (Q21): o interruptor é o do domínio do local (StockGate): a lista
# só traz os locais de domínio utilizável (com `pharmacy` desligado e
# `vector_control` utilizável, só os vector_control); criar confere o domínio
# do `kind` do corpo; editar, o do local. Domínio desligado → 403
# feature_disabled com a `feature` dele; nenhum → 403 com `pharmacy`.
module Pharmacy
  module Admin
    class LocationsController < BaseController
      skip_before_action :require_pharmacy!
      before_action :require_stock_location_kinds!
      before_action { forbid unless admin? }
      before_action :require_step_up!, only: %i[create update]

      def index
        render json: { locations: Json.admin_locations(pharmacy_locations.includes(:health_unit).order(:name, :id)) }
      end

      def create
        kind = body["kind"]
        return unless stock_feature_for!(StockLocation.new(kind: Catalog::STOCK_LOCATION_KINDS.include?(kind) ? kind : "central"))

        result = SaveLocation.call(attrs: body, by: Current.user)
        return render_failure(result) if result.failure?

        render json: Json.admin_locations([ result.payload.fetch(:location) ]).first, status: :created
      end

      def update
        location = uuid?(params[:id]) && StockLocation.where(kind: Catalog::STOCK_LOCATION_KINDS).find_by(id: params[:id])
        return not_found unless location
        return unless stock_feature_for!(location)

        result = SaveLocation.call(attrs: body, by: Current.user, location: location)
        return render_failure(result) if result.failure?

        render json: Json.admin_locations([ result.payload.fetch(:location) ]).first
      end

      private

      def pharmacy_locations = StockLocation.where(kind: usable_stock_location_kinds)
    end
  end
end
