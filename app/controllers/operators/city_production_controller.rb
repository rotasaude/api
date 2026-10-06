# GET /city_production (ADR 0028; contratos §4.3): produção LEDI de todas as
# cidades, no console do operador. Só plataforma; envelope { data: ... }.
module Operators
  class CityProductionController < BaseController
    def index
      render json: { data: Ledi::CityProductionQuery.call }
    end
  end
end
