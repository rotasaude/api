# GET /citizen/neighborhoods — bairros ATIVOS da cidade, por nome, para a
# escolha do cidadão (ADR 0023): inativo não entra em escolha nova. Envelope
# { neighborhoods: [...] }, como { people: [...] }.
module CitizenApi
  class NeighborhoodsController < BaseController
    def index
      rows = Neighborhood.active_neighborhoods.order(:name).map { |n| { id: n.id, name: n.name } }
      render json: { neighborhoods: rows }
    end
  end
end
