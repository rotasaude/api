# GET /regulation/rnds/syncs e POST /regulation/rnds/syncs/:id/retry (módulo 26c,
# Task 14; contrato §5, Q10, Q11). A lista (municipal_admin ou care_regulator,
# interruptor LIGADO) não traz paciente, CID, alvo nem payload: o número do
# pedido (`request_ref`), a situação, os motivos, os códigos da RNDS, as datas e
# o atalho de correção. O reenvio (só municipal_admin, step-up, interruptor
# UTILIZÁVEL) é de `rejected`/`failed`.
#
# Filtro `reason` (M22): um de BLOCK_REASONS (em `blocked_reasons`), um código da
# RNDS (`ERROR_CODE`, em `last_error_codes`, qualquer situação: uma linha
# `queued` com a recusa de um DELETE de duplicado também casa) ou `skeleton`
# (qualquer `skeleton:<caminho>`). Caminho de esqueleto avulso não é aceito.
module CareRegulation
  class RndsSyncsController < BaseController
    include ::RegulationRndsGate

    LIST_PARAMS = %w[status reason before limit].freeze
    SKELETON = "skeleton".freeze

    before_action { forbid unless admin? || regulator? }
    before_action :require_rnds_regulation_enabled!, only: :index
    before_action(only: :retry) { forbid unless admin? }
    before_action :require_rnds_regulation!, only: :retry
    before_action :require_step_up!, only: :retry

    def index
      return unless query_only!(*LIST_PARAMS)

      limit = page_limit
      return unless limit

      scope = filtered(RegulationRndsSync.all)
      return unless scope

      scope = after_cursor(scope, params[:before]) if params[:before].present?
      rows = scope.order(enqueued_at: :desc, id: :desc).preload(Regulation::RndsJson::PRELOAD).limit(limit + 1).to_a
      more = rows.size > limit
      rows = rows.first(limit)
      now = Time.current
      render json: { items: rows.map { |row| Regulation::RndsJson.item(row, now: now) },
                     next_before: more ? Cursor.encode_page(rows.last.enqueued_at, rows.last.id) : nil }
    rescue Cursor::Invalid
      render_error("invalid_cursor")
    end

    def retry
      sync = uuid?(params[:id]) && RegulationRndsSync.preload(Regulation::RndsJson::PRELOAD).find_by(id: params[:id])
      return not_found unless sync

      result = Regulation::RetryRndsSync.call(sync: sync, by: Current.user)
      return render_failure(result) if result.failure?

      render json: Regulation::RndsJson.item(result.payload.fetch(:sync), now: Time.current)
    end

    private

    # Devolve nil depois de responder 422 (valor fora do catálogo).
    def filtered(scope)
      status = params[:status]
      if status.present?
        return invalid("status") unless status.is_a?(String) && Regulation::RndsCatalog::SYNC_STATUSES.include?(status)

        scope = scope.where(status: status)
      end
      reason = params[:reason]
      reason.present? ? by_reason(scope, reason) : scope
    end

    def by_reason(scope, reason)
      return invalid("reason") unless reason.is_a?(String)

      if Regulation::RndsCatalog::BLOCK_REASONS.include?(reason)
        scope.where("blocked_reasons @> ARRAY[?]::text[]", reason)
      elsif reason.match?(Regulation::RndsLimits::ERROR_CODE)
        scope.where("last_error_codes @> ARRAY[?]::text[]", reason)
      elsif reason == SKELETON
        scope.where("EXISTS (SELECT 1 FROM unnest(regulation_rnds_syncs.blocked_reasons) AS r WHERE r LIKE 'skeleton:%')")
      else
        invalid("reason")
      end
    end

    def after_cursor(scope, raw)
      enqueued_at, id = Cursor.decode_page(raw)
      scope.where("(regulation_rnds_syncs.enqueued_at, regulation_rnds_syncs.id) < (?, ?)", enqueued_at, id)
    end

    def invalid(path)
      render json: { error: "invalid_request", path: path }, status: :unprocessable_entity
      nil
    end
  end
end
