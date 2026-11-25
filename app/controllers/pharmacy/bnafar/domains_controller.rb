# GET /pharmacy/bnafar/domains (módulo 27b; contrato §3, §6; Q16, Q19, Q20;
# R13, R16): os domínios do SI-BNAFAR para os formulários — os programas de
# saúde (DM14), os quatro tipos da saída externa (DM12) e os tipos de local
# (DM01) — e `enabled_domains`, os domínios com o envio utilizável (a entrada
# exige os campos de envio só neles; `[]` com o `bnafar` desligado). Exige só o
# estoque do domínio (`require_stock_feature!`), nunca o `bnafar`; qualquer papel
# do estoque (ou o `municipal_admin`).
module Pharmacy
  module Bnafar
    class DomainsController < ::Pharmacy::BaseController
      skip_before_action :require_pharmacy!
      before_action :require_stock_feature!

      def show
        return unless query_only!
        return forbid unless admin? || stock_role?

        render json: {
          programs: ::Bnafar::Domains.programs.map { |row| { code: row["code"], label: row["label"], product_type: row["product_type"] } },
          exit_types: ::Bnafar::Catalog::EXTERNAL_EXIT_TYPES.map { |code| { code: code, label: ::Bnafar::Domains.dm12.fetch(code) } },
          location_types: ::Bnafar::Domains.mappings.fetch("location_types").map { |kind, code| { kind: kind, code: code } },
          enabled_domains: ::Bnafar::Gate.domains(Current.city)
        }
      end

      private

      def stock_role? = Access.roles_by_location(Current.user).any? || Vaccination::Access.rooms_for(Current.user).any?
    end
  end
end
