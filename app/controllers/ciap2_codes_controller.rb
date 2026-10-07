# Busca de CIAP-2 por nome ou código para a queixa da escuta (ADR 0030; spec
# §8; contrato §9). Release ativa da plataforma; até 20. O termo vai no corpo
# (POST), nunca na URL. Sem release ativa: 503 terminology_unavailable.
class Ciap2CodesController < ApplicationController
  include Authentication
  include AttendanceAccess

  wrap_parameters false

  before_action :require_professional

  def search
    return render(json: { error: "terminology_unavailable" }, status: :service_unavailable) unless Screenings::Ciap2.release

    items = Screenings::Ciap2.search(params[:q].is_a?(String) ? params[:q] : "")
    render json: { items: items.map { |c| { code: c.code, label: c.label } } }
  end
end
