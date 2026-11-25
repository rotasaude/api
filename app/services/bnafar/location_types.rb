# DM01: tipo do estabelecimento pelo tipo do local de estoque (módulo 27b, Valor 5).
module Bnafar
  module LocationTypes
    module_function

    # `location` responde a `kind`. Tipo desconhecido levanta KeyError.
    def for(location) = Domains.mappings.fetch("location_types").fetch(location.kind.to_s)
  end
end
