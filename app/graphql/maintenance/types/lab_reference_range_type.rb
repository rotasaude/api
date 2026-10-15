module Maintenance
  module Types
    class LabReferenceRangeType < BaseObject
      graphql_name "LabReferenceRange"
      description "Faixa de referência de partida (Divergência M5)"

      field :sex, String, null: false
      field :age_min_days, Int, null: false
      field :age_max_days, Int, null: false
      field :low, Float, null: true
      field :high, Float, null: true
      field :text, String, null: true

      def sex = object["sex"]
      def age_min_days = object["age_min_days"]
      def age_max_days = object["age_max_days"]
      def low = object["low"]
      def high = object["high"]
      def text = object["text"]
    end
  end
end
