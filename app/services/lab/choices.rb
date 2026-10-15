# Lista de opções de um componente `choice` (catálogo-base e versões da
# cidade, mesma regra): 1 a 20 opções, cada uma de 1 a 60 caracteres (já sem
# espaços nas pontas), sem repetição.
module Lab
  module Choices
    MAX = 20
    MAX_LENGTH = 60

    module_function

    def normalize(raw) = Array(raw).map { |c| c.to_s.strip }

    def valid?(choices)
      choices.size.between?(1, MAX) && choices.uniq.size == choices.size &&
        choices.all? { |c| c.length.between?(1, MAX_LENGTH) }
    end
  end
end
