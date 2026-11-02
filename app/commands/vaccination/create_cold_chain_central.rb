# Cria a rede de frio municipal (ADR 0047, Desvio 4): o local de estoque
# `cold_chain_central`, um só na cidade (`already_exists`). Nome de 3 a 120
# caracteres, único sem diferenciar caixa. A equipe (stock_keeper) vai pelo
# /pharmacy/admin existente.
module Vaccination
  module CreateColdChainCentral
    NAME_LENGTH = (3..Pharmacy::Catalog::NAME_MAX)

    module_function

    # -> Result.ok(location:) | fail(:invalid_request, details: { path: "name" }) | fail(:already_exists)
    def call(name:, by:)
      name = name.strip if name.is_a?(String)
      return refuse unless name.is_a?(String) && NAME_LENGTH.cover?(name.length)

      StockLocation.transaction(requires_new: true) do
        next Result.fail(:already_exists) if StockLocation.exists?(kind: "cold_chain_central")
        next refuse if StockLocation.exists?([ "lower(name) = lower(?)", name ])

        Result.ok(location: StockLocation.create!(kind: "cold_chain_central", name: name, updated_by_user: by))
      end
    rescue ActiveRecord::RecordNotUnique => e
      e.message.include?("one_cold_chain_central") ? Result.fail(:already_exists) : refuse
    end

    def refuse = Result.fail(:invalid_request, details: { path: "name", problems: [ { path: "name", error: "invalid_request" } ] })
    private_class_method :refuse
  end
end
