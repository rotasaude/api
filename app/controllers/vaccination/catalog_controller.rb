# GET /vaccination/catalog (contrato §4): catálogo, terminologias e versão do
# calendário. Quem tem alguma sala ativa ou papel na rede de frio. Sem trilha:
# não traz dado de pessoa.
module Vaccination
  class CatalogController < BaseController
    def show
      return unless query_only!
      return forbid unless Access.rooms_for(Current.user).any? || cold_chain_member?

      render json: { calendar_version: Calendar.current.version,
                     immunobiologicals: Immunobiologicals.all.map { |product| product_json(product) },
                     terminologies: Terminologies::KINDS.index_with { |kind| Terminologies.list(kind) } }
    end

    private

    def cold_chain_member?
      central = StockLocation.active_locations.find_by(kind: "cold_chain_central")
      central.present? && Access.cold_chain_roles(user: Current.user, location: central).any?
    end

    def product_json(product)
      { code: product.code, name: product.name, multidose: product.multidose, doses_per_vial: product.doses_per_vial,
        default_route: product.default_route, default_site: product.default_site,
        manufacturers: product.manufacturers.map do |m|
          { code: m.code, name: m.name, validity_after_opening_hours: m.validity_after_opening_hours }
        end }
    end
  end
end
