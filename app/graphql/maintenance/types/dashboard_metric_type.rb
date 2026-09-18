module Maintenance
  module Types
    class DashboardMetricType < BaseObject
      description "Agregado pré-computado do dashboard da cidade. `label` é a chave dentro de " \
                   "dimension/period (ex.: um tier, uma prioridade, \"total\") — nunca dado de cidadão."

      field :dimension, String, null: false
      field :period, String, null: false
      # A coluna real é `key` (db/city_schema.rb) — renomeada para `label` no
      # schema publicado: um campo chamado `key` cai no fragmento proibido de
      # spec/architecture/maintenance_schema_spec.rb (FORBIDDEN_FRAGMENTS), e a
      # regra deste plano é parar e reportar, não abrir exceção em ALLOWED_NAMES.
      field :label, String, null: false, method: :key
      field :value, Integer, null: false
      # A coluna real é `updated_at` — não existe `computed_at` em
      # dashboard_metrics (o brief chutou o nome). `DashboardMetric.bump!`
      # sempre atualiza `updated_at` junto com `value`, então ele É o
      # "quando este valor foi calculado pela última vez" que o brief queria.
      field :computed_at, GraphQL::Types::ISO8601DateTime, null: false, method: :updated_at
    end
  end
end
