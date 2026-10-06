# Interface de ficha LEDI (spec §6.2; ADR 0028, "Consequências"): os módulos 18,
# 19, 22 e 24 produzem fichas que respondem a estes métodos. Ledi::Enqueue chama
# assert! antes de gravar.
#   type        -> String   chave de Ledi::FichaTypes ("procedimento")
#   competence  -> String   "AAAAMM" do atendimento, no fuso da cidade
#   cnes        -> String   7 dígitos
#   ine         -> String|nil 10 dígitos
#   to_thrift(uuid:) -> struct Thrift mestre da ficha, com o uuid dado
#   source      -> { type: String, id: String } (o registro que gerou a ficha)
module Ledi
  module Ficha
    class Invalid < StandardError; end

    METHODS = %i[type competence cnes ine to_thrift source].freeze

    module_function

    def assert!(ficha)
      missing = METHODS.reject { |m| ficha.respond_to?(m) }
      raise Invalid, "faltam: #{missing.join(', ')}" if missing.any?
      raise Invalid, "competence" unless ficha.competence.to_s.match?(/\A\d{4}(0[1-9]|1[0-2])\z/)
      raise Invalid, "cnes" unless ficha.cnes.to_s.match?(/\A\d{7}\z/)
      raise Invalid, "ine" unless ficha.ine.nil? || ficha.ine.to_s.match?(/\A\d{10}\z/)

      source = ficha.source
      unless source.is_a?(Hash) && source[:type].is_a?(String) && source[:id].is_a?(String)
        raise Invalid, "source"
      end
      Ledi::FichaTypes.code(ficha.type)
      ficha
    end
  end
end
