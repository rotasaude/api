module Maintenance
  module Types
    # A faixa de alerta do envio (Bnafar::Alert): só contagens e uma data.
    class BnafarAlertType < BaseObject
      graphql_name "BnafarAlert"
      description "Alerta do envio à BNAFAR: remessas atrasadas, perdidas e registros recusados"

      field :late, Integer, null: false
      field :lost, Integer, null: false
      field :rejected, Integer, null: false
      field :last_finished_on, GraphQL::Types::ISO8601Date, null: true

      def late = object[:late]
      def lost = object[:lost]
      def rejected = object[:rejected]
      def last_finished_on = object[:last_finished_on]
    end
  end
end
