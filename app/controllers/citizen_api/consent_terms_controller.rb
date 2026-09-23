# GET /citizen/consent_term — o termo vigente da cidade, mostrado antes do CPF.
module CitizenApi
  class ConsentTermsController < BaseController
    def show
      term = ConsentTerm.order(Arel.sql("version::bigint DESC")).first
      return render_error("no_consent_term", :service_unavailable) unless term

      render json: { version: term.version, body: term.body }
    end
  end
end
