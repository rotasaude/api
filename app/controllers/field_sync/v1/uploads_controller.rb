# POST /field/v1/uploads (módulo 24b, ADR 0052; contrato §9.3; Q31): o envio
# do app. A borda é a da FieldAuthentication (429, 403 feature_disabled, 401,
# 415 json_required, 413 payload_too_large). O corpo é lido do JSON cru (não dos
# params do Rails, que mexem em nulos e listas): envelope inválido → 422
# invalid_request com `path`, nada gravado; senão 200 { results } um por item
# (FieldSync::Upload). `items` e `body` já estão no filter_parameters.
module FieldSync
  module V1
    class UploadsController < BaseController
      def create
        envelope = FieldSync::Upload.envelope(parsed_body)
        if envelope.failure?
          return render(json: { error: "invalid_request", path: envelope.details[:path] }, status: :unprocessable_entity)
        end

        # Pode trazer pessoa (candidates, current do stale_version).
        response.headers["Cache-Control"] = "no-store"
        render json: { results: FieldSync::Upload.call(items: envelope.payload[:items], device: @device, user: @device_user) }
      end

      private

      def parsed_body
        JSON.parse(request.raw_post)
      rescue JSON::ParserError
        nil
      end
    end
  end
end
