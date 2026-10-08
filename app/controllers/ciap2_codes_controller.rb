# Busca de CIAP-2 por nome ou código para a queixa da escuta (ADR 0030; spec
# §8; contrato §9). Release ativa da plataforma; até 20. O termo vai no corpo
# (POST), nunca na URL. Sem release ativa: 503 terminology_unavailable.
# ADR 0031: também CID-10 (terminology: "cid10").
class Ciap2CodesController < ApplicationController
  include Authentication
  include AttendanceAccess

  wrap_parameters false

  before_action :require_professional

  # ADR 0031 (contratos §5): `terminology` cid10 busca na CID-10 ativa; padrão ciap2.
  def search
    terminology = params.key?(:terminology) ? params[:terminology] : "ciap2"
    return render(json: { error: "invalid_terminology" }, status: :unprocessable_entity) unless %w[ciap2 cid10].include?(terminology)

    query = params[:q].is_a?(String) ? params[:q] : ""
    if terminology == "cid10"
      return render(json: { error: "terminology_unavailable" }, status: :service_unavailable) unless ClinicalTerms.release("cid10")

      return render json: { items: ClinicalTerms.search("cid10", query).map { |c| { code: c.code, label: c.label } } }
    end
    return render(json: { error: "terminology_unavailable" }, status: :service_unavailable) unless Screenings::Ciap2.release

    render json: { items: Screenings::Ciap2.search(query).map { |c| { code: c.code, label: c.label } } }
  end
end
