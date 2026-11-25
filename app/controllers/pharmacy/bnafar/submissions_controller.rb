# Remessas ao SI-BNAFAR (módulo 27b; contrato §3, §6; Q16; R12). Exigem o `bnafar`.
#
#   GET  /pharmacy/bnafar/submissions?from=&to=&subject=&status=&before=&limit=
#        → { items: [<remessa>], next_before } (reference_on, id desc; 50, máx. 100)
#   GET  /pharmacy/bnafar/submissions/:id
#        → <remessa> + batches: [{ operation, status, protocol }] + records
#          (<registro>, página por `before`/`limit`, filtro `status`) + next_before
#   POST /pharmacy/bnafar/submissions/:id/retry → o reenvio dos recusados
#        (`municipal_admin`, step-up; 409 retry_window_closed | nothing_to_retry)
#
# Leitura: `municipal_admin` ou `stock_keeper` de qualquer local; query com
# chave fora da lista → 422 com o path (só o nome). Nunca o payload.
module Pharmacy
  module Bnafar
    class SubmissionsController < BaseController
      def index
        return unless bnafar_reader!
        return unless query_only!(:from, :to, :subject, :status, :before, :limit)

        scope = filtered(BnafarSubmission.where(environment: environment)) or return
        limit = page_limit or return
        cursor = params.key?(:before) ? ::Pharmacy::Cursor.decode(params[:before]) : nil
        return render_refusal("before", "invalid_cursor") if params.key?(:before) && !day_cursor?(cursor)

        scope = scope.where("(bnafar_submissions.reference_on, bnafar_submissions.id) < (?, ?)", Date.iso8601(cursor.first), cursor.last) if cursor
        rows = scope.order(reference_on: :desc, id: :desc).limit(limit + 1).to_a
        page = rows.first(limit)
        tallies = ::Bnafar::Json.counts(page.index_by(&:id))
        render json: { items: page.map { |row| ::Bnafar::Json.submission(row, tally: tallies.fetch(row.id)) },
                       next_before: rows.size > limit ? ::Pharmacy::Cursor.encode([ page.last.reference_on.iso8601, page.last.id ]) : nil }
      end

      def show
        return unless bnafar_reader!
        return unless query_only!(:status, :before, :limit)

        submission = submission_param or return not_found
        status = params[:status]
        return render_refusal("status") if params.key?(:status) && !::Bnafar::Catalog::RECORD_STATUSES.include?(status)

        limit = page_limit or return
        cursor = params.key?(:before) ? ::Pharmacy::Cursor.decode(params[:before]) : nil
        return render_refusal("before", "invalid_cursor") if params.key?(:before) && !valid_cursor?(cursor)

        scope = submission.records
        scope = scope.where(status: status) if status
        scope = scope.where("(bnafar_records.created_at, bnafar_records.id) < (?, ?)", Time.iso8601(cursor.first), cursor.last) if cursor
        rows = scope.includes(*::Bnafar::Json::RECORD_PRELOAD).order(created_at: :desc, id: :desc).limit(limit + 1).to_a
        page = rows.first(limit)
        labels = ::Bnafar::Json.labels(page)
        batches = submission.batches.order(:created_at, :id).map { |batch| { operation: batch.operation, status: batch.status, protocol: batch.protocol } }
        render json: ::Bnafar::Json.submission(submission).merge(
          batches: batches, records: page.map { |row| ::Bnafar::Json.record(row, label_index: labels) },
          next_before: rows.size > limit ? ::Pharmacy::Cursor.encode([ page.last.created_at.utc.iso8601(6), page.last.id ]) : nil
        )
      end

      def resend
        return forbid unless admin?

        submission = submission_param or return not_found
        require_step_up!
        return if performed?

        domains = ::Bnafar::Gate.domains_through(Current.city, submission.reference_on)
        result = ::Bnafar::RetrySubmission.call(submission: submission, by: Current.user, today: Time.zone.today, domains: domains)
        return render_failure(result) if result.failure?

        batch = result.payload.fetch(:batch)
        render json: { batch: { id: batch.id, operation: batch.operation, status: batch.status, protocol: batch.protocol },
                       retried: result.payload.fetch(:records).size,
                       submission: ::Bnafar::Json.submission(submission.reload) }
      end

      private

      # Os filtros `from`, `to`, `subject`, `status`; filtro inválido → 422 e nil.
      def filtered(scope)
        { from: :from, to: :to }.each_key do |key|
          next unless params.key?(key)

          day = date_param(key)
          return render_refusal(key.to_s) && nil unless day

          scope = scope.where(key == :from ? "reference_on >= ?" : "reference_on <= ?", day)
        end
        { subject: ::Bnafar::Catalog::SUBJECTS, status: ::Bnafar::Catalog::SUBMISSION_STATUSES }.each do |key, allowed|
          next unless params.key?(key)
          return render_refusal(key.to_s) && nil unless allowed.include?(params[key])

          scope = scope.where(key => params[key])
        end
        scope
      end

      def day_cursor?(cursor)
        cursor && cursor.size == 2 && uuid?(cursor.last) && cursor.first.match?(/\A\d{4}-\d{2}-\d{2}\z/) && Date.iso8601(cursor.first)
      rescue Date::Error
        false
      end
    end
  end
end
