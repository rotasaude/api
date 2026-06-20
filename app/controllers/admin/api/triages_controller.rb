class Admin::Api::TriagesController < Admin::Api::BaseController
  def show
    data = Admin::TriagesQuery.call(municipality: current_municipality, period: period)
    render_envelope(data)
  end

  # GET /admin/api/triages/:id/trail — referências apenas (ADR 0015).
  def trail
    data = Admin::TriageTrailQuery.call(municipality: current_municipality, triage_id: params[:id])
    return head :not_found unless data
    render_envelope(data)
  end
end
