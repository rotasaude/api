require "base64"

# /vector_control/samples (módulo 35a, ADR 0054; contrato §9, §12; Q8, Q9):
# as amostras de larvas da coordenação e do vector_lab (403 missing_role para
# os outros).
#   - GET /samples?state=pending|done&before= (padrão pending): `{ items,
#     next_before }` de VectorSample das visitas não retiradas, sem (pending)
#     ou com (done) resultado, por (dia da visita no fuso da cidade, label),
#     a mais antiga primeiro. O cursor é a chave de ordem do último item
#     (base64url de "dia|label"); adulterado → 422 invalid_cursor;
#   - POST /samples/:id/result `{ examined_larvae, aegypti_larvae,
#     albopictus_larvae, result_note? }` (VectorControl::RecordSampleResult)
#     → VectorSample. Amostra inexistente ou de visita retirada → 404.
# Sem imóvel nem pessoa: a etiqueta, o dia, o grupo e o quarteirão. A nota
# nunca sai; `result.corrected` diz se houve correção.
module VectorControl
  class SamplesController < BaseController
    STATES = %w[pending done].freeze
    BODY_KEYS = %w[examined_larvae aegypti_larvae albopictus_larvae result_note].freeze
    LIMIT = 50
    CURSOR = /\A(\d{4}-\d{2}-\d{2})\|([0-9A-F]{8}-\d{2})\z/

    before_action(only: :result) { query_only! }
    before_action :reader!

    def index
      return unless query_only!(:state, :before)

      state = request.query_parameters.fetch("state", "pending")
      return render_refusal("invalid_request", path: "state") unless STATES.include?(state)

      after = sample_cursor(request.query_parameters["before"])
      return render_refusal("invalid_cursor") if after == :invalid

      rows = queue(state, after).limit(LIMIT + 1).to_a
      shown = rows.first(LIMIT)
      next_before = rows.size > LIMIT ? encode_cursor(shown.last) : nil
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
      day = visit_day_sql
      scope = VectorSample.joins(vector_inspection: :home_visit).merge(HomeVisit.valid)
                          .select("vector_samples.*", "#{day} AS visit_day")
      scope = state == "pending" ? scope.where(result_at: nil) : scope.where.not(result_at: nil)
      scope = scope.where("(#{day}, vector_samples.label) > (?, ?)", *after) if after
      scope.order(Arel.sql("#{day}, vector_samples.label"))
    end

    def encode_cursor(sample) = Base64.urlsafe_encode64("#{sample.visit_day.iso8601}|#{sample.label}", padding: false)

    # [dia, label] do cursor; nil sem cursor; :invalid adulterado.
    def sample_cursor(raw)
      return nil if raw.nil? || raw == ""
      return :invalid unless raw.is_a?(String)

      match = Base64.urlsafe_decode64(raw).match(CURSOR)
      match ? [ Date.iso8601(match[1]), match[2] ] : :invalid
    rescue ArgumentError, EncodingError, Date::Error
      :invalid
    end
  end
end
