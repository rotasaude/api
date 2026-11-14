# GET /field/v1/map (módulo 24c, ADR 0053; contrato §3.1): o mapa offline da
# cidade para o aparelho, pela borda do app de campo (sem query, sem trilha).
# Inteiro ou por intervalo (`Range`, `If-Range`), com o SHA-256 como ETag.
module FieldSync
  module V1
    class MapsController < BaseController
      include ::FieldMapDelivery

      def show
        render_field_map(FieldMap.published_for(Current.city.id))
      end
    end
  end
end
