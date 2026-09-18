module Maintenance
  module Types
    class ProtocolDefinitionType < BaseObject
      description "Definição de protocolo, metadado apenas (ver ADR-0009)."

      field :name, String, null: false
      field :version, Integer, null: false
      field :status, String, null: false
    end
  end
end
