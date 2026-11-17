# /vector_control/ovitrap_readings (módulo 35a, ADR 0054; contrato §6, §12;
# Q8, Q9): as palhetas da coordenação e do vector_lab (403 missing_role para
# os outros).
#   - GET /ovitrap_readings?state=to_count|counted&before= (padrão to_count):
#     `{ items, next_before }` de OvitrapReading, mais recente primeiro.
#     to_count = coletada boa sem contagem; counted = com contagem;
#   - POST /ovitrap_readings/:id/count `{ egg_count, count_note? }`
#     (VectorControl::CountReading) → OvitrapReading.
# Sem domicílio nem pessoa: a ovitrampa, o quarteirão e o bairro. A nota nunca
# sai; `corrected` diz se houve correção.
module VectorControl
  class OvitrapReadingsController < BaseController
    STATES = %w[to_count counted].freeze
    LIMIT = 50

    before_action(only: :count) { query_only! }
    before_action :reader!

    def index
      return unless query_only!(:state, :before)

      state = request.query_parameters.fetch("state", "to_count")
      return render_refusal("invalid_request", path: "state") unless STATES.include?(state)

      position = cursor
      return if performed?

      scope = state == "to_count" ? OvitrapReading.pending_counts : OvitrapReading.where.not(egg_count: nil)
      rows, next_before = page(scope, :created_at, limit: LIMIT, position: position)
      render json: { items: Json.ovitrap_readings(rows), next_before: next_before }
    end

    def count
      reading = OvitrapReading.find_by(id: params[:id])
      return not_found unless reading

      unknown = (body.keys - %w[egg_count count_note]).first
      return render_refusal("invalid_request", path: unknown) if unknown

      result = CountReading.call(reading: reading, egg_count: body_param("egg_count"), note: body_param("count_note"), by: Current.user)
      return render_failure(result) if result.failure?

      render json: Json.ovitrap_readings([ result.payload[:reading] ]).sole
    end

    private

    # Só a coordenação e o vector_lab; senão 403 missing_role (false).
    def reader!
      return true if Access.coordinator?(Current.user) || Access.lab?(Current.user)

      forbid
      false
    end
  end
end
