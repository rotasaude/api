# GET /pharmacy/locations (contrato §13 H2): meus locais, com os papéis do
# usuário em cada um. O almoxarife do central vê todos os locais ativos (os
# alheios vêm com `roles: []`). Quem não tem papel válido recebe lista vazia.
#
# Módulo 35a (Q21): o interruptor é o do domínio de cada local (StockGate):
# saem só os locais de domínio utilizável. Nenhum domínio utilizável → 403
# feature_disabled `pharmacy`; o usuário com locais, todos de domínio
# desligado → 403 feature_disabled com a `feature` do primeiro.
module Pharmacy
  class LocationsController < BaseController
    skip_before_action :require_pharmacy!
    before_action :require_stock_location_kinds!

    def index
      roles = Access.roles_by_location(Current.user)
      all = Access.locations_for(Current.user)
      visible = all.select { |location| usable_stock_location_kinds.include?(location.kind) }
      return stock_feature_for!(all.first) if visible.empty? && all.any?

      rows = visible.map do |location|
        Json.location(location).merge(roles: roles.fetch(location.id, Set.new).to_a.sort)
      end
      render json: { locations: rows }
    end
  end
end
