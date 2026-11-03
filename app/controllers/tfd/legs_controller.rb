# Trechos e ajuda de custo do TFD (contrato §6; §14 T8, T10, T11), pela
# comissão (outro papel → 403 missing_role; rascunho → 404, como nas outras
# escritas dela):
#   POST /tfd/cases/:id/legs       { direction, mode, date, trip_passenger_id?, ticket?, companion? } → <tfd-case>
#   POST /tfd/legs/:id/done        trecho de passagem feito (frota → fleet_leg_by_trip) → <tfd-case>
#   GET  /tfd/cases/:id/allowances { items: [<tfd-allowance>], total_cents }
# Sem trilha (as escritas devolvem o <tfd-case> como as da Task 10; a lista da
# ajuda de custo não leva dado do paciente).
module Tfd
  class LegsController < BaseController
    before_action :require_committee!
    before_action :load_case, only: %i[create allowances]

    def create
      return unless query_only!

      result = AddLeg.call(tfd_case: @tfd_case, attrs: body, by: Current.user)
      return render_failure(result) if result.failure?

      render json: Json.case(@tfd_case.reload)
    end

    def done
      return unless query_only!

      leg = uuid?(params[:id]) ? TfdLeg.find_by(id: params[:id]) : nil
      return not_found unless leg

      result = CompleteLeg.call(leg: leg, by: Current.user)
      return render_failure(result) if result.failure?

      render json: Json.case(leg.tfd_case.reload)
    end

    def allowances
      return unless query_only!

      rows = @tfd_case.tfd_allowances.order(:created_at, :id).to_a
      render json: { items: rows.map { |row| Json.allowance(row) }, total_cents: rows.sum(&:total_cents) }
    end

    private

    def require_committee!
      forbid unless Access.committee?(Current.user)
    end

    def load_case
      @tfd_case = uuid?(params[:id]) ? TfdCase.find_by(id: params[:id]) : nil
      @tfd_case = nil if @tfd_case&.status == "draft"
      not_found unless @tfd_case
    end
  end
end
