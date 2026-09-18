module Maintenance
  module Types
    class ProtocolDefinitionType < BaseObject
      description "Definição de protocolo, metadado apenas."

      field :name, String, null: false
      field :version, Integer, null: false
      field :status, String, null: false
    end
  end
end
