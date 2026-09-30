# GET /city_analytics (ADR 0025; contratos §2): indicadores publicados das
# cidades, no console do operador. Só plataforma.
module Operators
  class CityAnalyticsController < BaseController
    def index
      render json: { data: Analytics::CityIndicatorsQuery.call(from: params[:from], to: params[:to]) }
    rescue Analytics::Params::Invalid => e
      render json: { error: e.code }, status: :unprocessable_entity
    end
  end
end
