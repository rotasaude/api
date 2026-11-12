#   POST /citizen/ombudsman/anonymous_reports { body, health_unit_id? } → 201 { ok: true }
# Denúncia anônima sem login (ADR 0051; contrato §4; §16 Q1, Q8, Q29, Q41,
# Q43): o primeiro formulário público de escrita. Sem protocolo na resposta.
# Ordem real das recusas (preflight F-16; o 415 vem do before_action do
# CitizenAuthentication, registrado antes dos desta classe):
#   415 json_required → 429 too_many_requests (3 por hora e 10 por dia por IP)
#   → 403 feature_disabled (ombudsman_anonymous_web, que exige ombudsman)
#   → 413 payload_too_large (Content-Length ou corpo acima de 16 KB; o JSON já
#     foi interpretado para o log, com `body` filtrado — Q29)
#   → 422 chave fora de `body`/`health_unit_id`, ou qualquer chave na query
#     (só o nome, truncado)
#   → Ombudsman::RegisterAnonymous (422 do texto e da unidade; 429
#     daily_cap_reached no teto da cidade).
# Rota pública (Q41): o limite é pelo IP, nunca pela sessão; nada aqui lê ou
# cria `citizen_session`, nem grava cookie.
module CitizenApi
  module Ombudsman
    class AnonymousReportsController < CitizenApi::BaseController
      include ::OmbudsmanGate

      wrap_parameters false
      allow_anonymous_citizen

      KEY_PATH_MAX = 64

      rate_limit to: 3, within: 1.hour, only: :create, name: "citizen_ombudsman_anonymous_hour",
                 by: -> { request.remote_ip }, store: RateLimitStore,
                 with: -> { render_error("too_many_requests", :too_many_requests) }
      rate_limit to: 10, within: 1.day, only: :create, name: "citizen_ombudsman_anonymous_day",
                 by: -> { request.remote_ip }, store: RateLimitStore,
                 with: -> { render_error("too_many_requests", :too_many_requests) }
      before_action :require_ombudsman_anonymous!
      before_action :require_small_body!
      before_action :require_known_keys!

      def create
        attrs = request.request_parameters
        result = ::Ombudsman::RegisterAnonymous.call(body: attrs["body"], health_unit_id: attrs["health_unit_id"])
        return render json: { ok: true }, status: :created if result.ok?
        return render_error("daily_cap_reached", :too_many_requests) if result.reason == :daily_cap_reached

        render_refusal(result.details.fetch(:path))
      end

      private

      def require_small_body!
        limit = ::Ombudsman::Catalog::ANONYMOUS_MAX_BODY_BYTES
        return unless request.content_length.to_i > limit || request.raw_post.bytesize > limit

        render_error("payload_too_large", :content_too_large)
      end

      def require_known_keys!
        unknown = (request.request_parameters.keys - ::Ombudsman::Catalog::ANONYMOUS_KEYS).first ||
                  request.query_parameters.keys.first
        render_refusal(unknown.to_s[0, KEY_PATH_MAX]) if unknown
      end

      def render_refusal(path)
        render json: { error: "invalid_request", path: path, problems: [ { error: "invalid_request", path: path } ] },
               status: :unprocessable_entity
      end
    end
  end
end
