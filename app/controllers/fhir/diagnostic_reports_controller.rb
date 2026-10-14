# POST /fhir/DiagnosticReport (contrato §7, A7): só application/fhir+json
# (415), corpo até 15 MB (413, lido com teto: sem confiar no Content-Length).
module Fhir
  class DiagnosticReportsController < BaseController
    MAX_BODY = 15 * 1024 * 1024
    STATUS = { order_not_found: :not_found, invalid_transition: :conflict }.freeze

    def create
      return fhir_error("unsupported_media_type", :unsupported_media_type) unless request.media_type == MEDIA_TYPE
      return fhir_error("payload_too_large", :payload_too_large) if request.content_length.to_i > MAX_BODY

      body = read_body
      return fhir_error("payload_too_large", :payload_too_large) if body.bytesize > MAX_BODY

      result = Exams::Fhir::Inbound.call(provider: @provider, resource: parse(body))
      if result.failure?
        return fhir_error(result.reason.to_s, STATUS.fetch(result.reason, :unprocessable_entity), details: result.details[:paths])
      end

      render json: { result_id: result.payload[:result].id }, status: result.payload[:created] ? :created : :ok
    end

    private

    def read_body
      request.body.rewind
      request.body.read(MAX_BODY + 1).to_s
    end

    def parse(body)
      JSON.parse(body)
    rescue JSON::ParserError
      nil
    end
  end
end
