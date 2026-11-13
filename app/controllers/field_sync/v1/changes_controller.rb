# GET /field/v1/changes?cursor=&limit= (módulo 24b, ADR 0052; contrato §9.3):
# o download incremental do escopo do aparelho (FieldSync::Changes). A borda é
# a da FieldAuthentication (429, 403 feature_disabled, 401). Só cursor e limit
# na query (o cursor é opaco e sem dado pessoal): limit fora de 1–500 → 422
# invalid_limit (padrão 200); cursor adulterado → 422 invalid_cursor; cursor
# vazio = sem cursor (carga completa). A resposta traz pessoa: no-store.
module FieldSync
  module V1
    class ChangesController < BaseController
      def index
        limit = page_limit
        return render(json: { error: "invalid_limit" }, status: :unprocessable_entity) unless limit

        cursor = request.query_parameters["cursor"]
        cursor = nil if cursor == ""
        page = FieldSync::Changes.page(user: @device_user, device: @device, cursor: cursor, limit: limit)
        response.headers["Cache-Control"] = "no-store"
        render json: page
      rescue FieldSync::Cursor::Invalid
        render json: { error: "invalid_cursor" }, status: :unprocessable_entity
      end

      private

      def permitted_query_keys = %w[cursor limit]

      # Inteiro decimal em 1–500; ausente (ou vazio) → 200; senão nil.
      def page_limit
        raw = request.query_parameters["limit"]
        return FieldSync::Catalog::DEFAULT_PAGE if raw.nil? || raw == ""
        return nil unless raw.is_a?(String)

        value = Integer(raw, 10, exception: false)
        value if value && FieldSync::Catalog::PAGE_LIMIT.cover?(value)
      end
    end
  end
end
