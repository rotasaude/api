# GET /admin/api/reports — lista de relatórios de uma cidade (F-04.6).
# Read-only, metadados apenas (LGPD) — ver Admin::ReportsQuery. Sem gate de
# operador: é painel POR CIDADE (como Triages); o BaseController escopa um
# não-operador à sua própria cidade (first_member_municipality).
class Admin::Api::ReportsController < Admin::Api::BaseController
  def show
    render_envelope(Admin::ReportsQuery.call(municipality: current_municipality, period: period))
  end
end
