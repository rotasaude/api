# POST /citizen/ombudsman/attachments { filename, content_type, data } (ADR 0051;
# contrato §3; Q2, Q43): o anexo da manifestação, em Base64, PDF/JPEG/PNG até
# 10 MB. Devolve só { id }; o dono é a sessão do cidadão, a linha nasce órfã e
# some em 24 h se ninguém a ligar. 20 por hora por sessão (429
# too_many_requests). O cidadão não baixa anexos (Q14). Nome e bytes só do
# corpo, nunca de log, evento ou erro: chave na query → 422 com o nome.
module CitizenApi
  module Ombudsman
    class AttachmentsController < CitizenApi::BaseController
      include ::OmbudsmanGate

      wrap_parameters false

      KEY_PATH_MAX = 64

      before_action :require_ombudsman!
      rate_limit to: 20, within: 1.hour, only: :create, name: "citizen_ombudsman_attachment",
                 by: -> { current_citizen_session&.id || request.remote_ip }, store: RateLimitStore,
                 with: -> { render_error("too_many_requests", :too_many_requests) }
      before_action :query_only!

      def create
        body = request.request_parameters
        result = ::Ombudsman::Attachments.upload(data: body["data"], content_type: body["content_type"], filename: body["filename"],
                                                 citizen_session: current_citizen_session)
        return render(json: { id: result.payload.fetch(:attachment).id }, status: :created) if result.ok?

        payload = { error: result.reason.to_s }
        %i[path problems].each { |key| payload[key] = result.details[key] if result.details[key] }
        render json: payload, status: :unprocessable_entity
      end

      private

      # Preflight F-14: nada de dado na URL — qualquer chave na query → 422.
      def query_only!
        unknown = request.query_parameters.keys.first
        return unless unknown

        path = unknown.to_s[0, KEY_PATH_MAX]
        render json: { error: "invalid_request", path: path, problems: [ { error: "invalid_request", path: path } ] },
               status: :unprocessable_entity
      end
    end
  end
end
