require "base64"

# /vector_control/samples (módulo 35a, ADR 0054; contrato §9, §12; Q8, Q9):
# as amostras de larvas da coordenação e do vector_lab (403 missing_role para
# os outros).
#   - GET /samples?state=pending|done&before= (padrão pending): `{ items,
#     next_before }` de VectorSample das visitas não retiradas. pending = sem
#     resultado, por (dia da visita no fuso da cidade, label), a mais antiga
#     primeiro; done = com resultado, por (result_at, id) decrescente, o
#     lançado ou corrigido por último primeiro (Q27). O cursor é a aba mais a
#     chave de ordem do último item (base64url de "pending|dia|label" ou
#     "done|instante|id"); adulterado ou da outra aba → 422 invalid_cursor;
#   - POST /samples/:id/result `{ examined_larvae, aegypti_larvae,
#     albopictus_larvae, result_note?, expected_version? }`
#     (VectorControl::RecordSampleResult) → VectorSample. Amostra inexistente
#     ou de visita retirada → 404. Q36: a correção leva expected_version (a
#     version lida): ausente → 422 expected_version_required, divergente →
#     409 sample_changed; no primeiro resultado → 422 invalid_request path
#     expected_version.
# Sem imóvel nem pessoa: a etiqueta, o dia, o grupo e o quarteirão. A nota
# nunca sai; `result.corrected` diz se houve correção.
module VectorControl
  class SamplesController < BaseController
    STATES = %w[pending done].freeze
    BODY_KEYS = %w[examined_larvae aegypti_larvae albopictus_larvae result_note expected_version].freeze
    LIMIT = 50
    CURSORS = {
      "pending" => /\Apending\|(\d{4}-\d{2}-\d{2})\|([0-9A-F]{8}-\d{2})\z/,
      "done" => /\Adone\|(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z)\|(\h{8}-\h{4}-\h{4}-\h{4}-\h{12})\z/
    }.freeze

    # O papel antes da query: quem não lê recebe 403 missing_role, não 422.
    before_action :reader!
    before_action(only: :result) { query_only! }

    def index
      return unless query_only!(:state, :before)

      state = request.query_parameters.fetch("state", "pending")
      return render_refusal("invalid_request", path: "state") unless STATES.include?(state)

      after = sample_cursor(state, request.query_parameters["before"])
      return render_refusal("invalid_cursor") if after == :invalid

      rows = queue(state, after).limit(LIMIT + 1).to_a
      shown = rows.first(LIMIT)
      next_before = rows.size > LIMIT ? encode_cursor(state, shown.last) : nil
      render json: { items: Json.samples(shown), next_before: next_before }
    end

    def result
      sample = VectorSample.find_by(id: params[:id])
      return not_found unless sample

      unknown = (body.keys - BODY_KEYS).first
      return render_refusal("invalid_request", path: unknown) if unknown

      outcome = RecordSampleResult.call(sample: sample, params: body, by: Current.user)
      return render_failure(outcome) if outcome.failure?

      render json: Json.samples([ outcome.payload.fetch(:sample) ]).sole
    end

    private

    # Só a coordenação e o vector_lab; senão 403 missing_role (false).
    def reader!
      return true if Access.coordinator?(Current.user) || Access.lab?(Current.user)

      forbid
      false
    end

    # Dia da visita no fuso da cidade (occurred_at é timestamp sem fuso, em UTC).
    def visit_day_sql
      zone = VectorSample.connection.quote(Time.zone.tzinfo.identifier)
      "((home_visits.occurred_at AT TIME ZONE 'UTC') AT TIME ZONE #{zone})::date"
    end

    def queue(state, after)
      scope = VectorSample.joins(vector_inspection: :home_visit).merge(HomeVisit.valid)
      return done_queue(scope, after) if state == "done"

      day = visit_day_sql
      scope = scope.where(result_at: nil).select("vector_samples.*", "#{day} AS visit_day")
      scope = scope.where("(#{day}, vector_samples.label) > (?, ?)", *after) if after
      scope.order(Arel.sql("#{day}, vector_samples.label"))
    end

    def done_queue(scope, after)
      scope = scope.where.not(result_at: nil)
      scope = scope.where("(vector_samples.result_at, vector_samples.id) < (?, ?)", *after) if after
      scope.order(result_at: :desc, id: :desc)
    end

    def encode_cursor(state, sample)
      key = state == "done" ? "#{sample.result_at.utc.iso8601(6)}|#{sample.id}" : "#{sample.visit_day.iso8601}|#{sample.label}"
      Base64.urlsafe_encode64("#{state}|#{key}", padding: false)
    end

    # A chave de ordem do cursor da aba (pending: [dia, label]; done:
    # [instante, id]); nil sem cursor; :invalid adulterado ou da outra aba.
    def sample_cursor(state, raw)
      return nil if raw.nil? || raw == ""
      return :invalid unless raw.is_a?(String)

      match = Base64.urlsafe_decode64(raw).match(CURSORS.fetch(state))
      return :invalid unless match

      state == "done" ? [ Time.iso8601(match[1]), match[2].downcase ] : [ Date.iso8601(match[1]), match[2] ]
    rescue ArgumentError, EncodingError, Date::Error
      :invalid
    end
  end
end
