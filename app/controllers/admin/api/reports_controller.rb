# GET /admin/api/reports — lista de relatórios de uma cidade (F-04.6).
# Read-only, metadados apenas (LGPD) — ver Admin::ReportsQuery.
# Restrito a operador (platform_operator), como Admin::Api::CitiesController.
class Admin::Api::ReportsController < Admin::Api::BaseController
  before_action :require_operator!

  def show
    render_envelope(Admin::ReportsQuery.call(municipality: current_municipality, period: period))
  end

  private

  def require_operator!
    head :forbidden unless cross_tenant?
  end
end
