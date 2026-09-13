class Admin::Api::TriagesController < Admin::Api::BaseController
  def show
    data = Admin::TriagesQuery.call(period: period)
    render_envelope(data)
  end

  # GET /admin/api/triages/:id/trail — referências apenas (ADR 0009).
  def trail
    data = Admin::TriageTrailQuery.call(triage_id: params[:id])
    return head :not_found unless data
    render_envelope(data)
  end
end
