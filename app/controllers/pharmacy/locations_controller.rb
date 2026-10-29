# GET /pharmacy/locations (contrato §13 H2): meus locais, com os papéis do
# usuário em cada um. O almoxarife do central vê todos os locais ativos (os
# alheios vêm com `roles: []`). Quem não tem papel válido recebe lista vazia.
module Pharmacy
  class LocationsController < BaseController
    def index
      roles = Access.roles_by_location(Current.user)
      rows = Access.locations_for(Current.user).map do |location|
        Json.location(location).merge(roles: roles.fetch(location.id, Set.new).to_a.sort)
      end
      render json: { locations: rows }
    end
  end
end
