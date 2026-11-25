# GET /pharmacy/obm_presentations?vmp_code= (módulo 27b, Task 13; Q16, Q19): as
# apresentações (AMPP) ATIVAS do OBM de um VMP, para o formulário do lote. Exige
# só o estoque do domínio (`require_stock_feature!`), nunca o `bnafar`; quem tem
# algum papel de estoque (ou o `municipal_admin`). O catálogo é da plataforma:
# nenhum dado de pessoa.
module Pharmacy
  class ObmPresentationsController < BaseController
    skip_before_action :require_pharmacy!
    before_action :require_stock_feature!

    def index
      return unless query_only!(:vmp_code)
      return forbid unless admin? || stock_role?

      vmp_code = params[:vmp_code]
      return render_refusal("vmp_code") unless vmp_code.is_a?(String) && vmp_code.match?(::Bnafar::Catalog::AMPP)

      rows = ObmPresentation.active.where(vmp_code: vmp_code).order(:ampp_code)
      render json: { items: rows.map do |row|
        { ampp_code: row.ampp_code, vmp_code: row.vmp_code, anvisa_registration: row.anvisa_registration,
          manufacturer_cnpj: row.manufacturer_cnpj, description: row.description }
      end }
    end

    private

    def stock_role? = Access.roles_by_location(Current.user).any? || Vaccination::Access.rooms_for(Current.user).any? || Access.central_keeper?(Current.user)
  end
end
