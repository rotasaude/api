# GET /fhir/ServiceRequest?status=active (contrato §7, A7): só `active`.
module Fhir
  class ServiceRequestsController < BaseController
    def index
      return fhir_error("invalid_search", :unprocessable_entity) unless params[:status] == "active"

      render body: Exams::Fhir::ServiceRequests.bundle(provider: @provider).to_json, content_type: MEDIA_TYPE
    end
  end
end
