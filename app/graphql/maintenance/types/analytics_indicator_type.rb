module Maintenance
  module Types
    class AnalyticsIndicatorType < BaseObject
      description "Indicador semanal publicado da cidade inteira (ADR 0025), lido do banco de plataforma. " \
                  "Suprimido (1 a 4, ou taxa com numerador/denominador nessa faixa) = value nulo."

      field :week_start, GraphQL::Types::ISO8601Date, null: false
      field :indicator, String, null: false
      field :value, Float, null: true
      field :suppressed, Boolean, null: false
    end
  end
end
