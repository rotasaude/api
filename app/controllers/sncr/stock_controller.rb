# Minha conta → SNCR (contrato §4): saldo do modo corrente da cidade.
module Sncr
  class StockController < BaseController
    def show
      return failure(Result.fail(:cbo_not_allowed)) unless StartRequest::COUNCILS.include?(Current.user.professional&.council)

      simulated = Mock.on?(Current.city)
      render json: Stock.summary(user: Current.user, simulated: simulated)
                        .merge(low_threshold: Stock::LOW_THRESHOLD, simulated: simulated)
    end
  end
end
