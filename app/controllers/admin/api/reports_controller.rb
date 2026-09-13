# GET /admin/api/reports — lista de relatórios de uma cidade (F-04.6).
# Read-only, metadados apenas (LGPD) — ver Admin::ReportsQuery. Sem gate de
# operador: é painel POR CIDADE (como Triages) — lê o banco da cidade do host.
class Admin::Api::ReportsController < Admin::Api::BaseController
  def show
    render_envelope(Admin::ReportsQuery.call(period: period))
  end
end
