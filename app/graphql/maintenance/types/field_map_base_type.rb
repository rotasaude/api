module Maintenance
  module Types
    # ADR 0053 (Q23): a base de onde saem os recortes por município. O aviso
    # dos 90 dias é calculado no maintenance, a partir de `ageDays`.
    class FieldMapBaseType < BaseObject
      description "Base pronta dos mapas de campo (a de maior versão)"

      field :version, GraphQL::Types::ISO8601Date, null: false
      field :age_days, Integer, null: false

      def age_days = object.age_days(Time.zone.today)
    end
  end
end
