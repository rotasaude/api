module Maintenance
  module Types
    class AlertRecipientType < BaseObject
      description "Destinatário de alerta urgente da cidade. Só configuração (ADR-0013)."

      field :channel, String, null: false
      field :destination, String, null: false
      field :escalation_order, Integer, null: false
    end
  end
end
