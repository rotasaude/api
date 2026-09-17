module Maintenance
  module Types
    class UserErrorType < BaseObject
      description "Erro de regra de negócio, já esperado — não é falha de sistema"

      field :path, String, null: true, description: "Campo de entrada que causou o erro, quando há um"
      field :message, String, null: false
    end
  end
end
