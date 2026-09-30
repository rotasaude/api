module Maintenance
  module Types
    class AnalyticsStatusType < BaseObject
      description "Estado da consolidação do Analytics da cidade (analytics_runs). lastError é classe e primeira " \
                  "linha da mensagem, nunca payload."

      field :last_run_status, String, null: true
      field :last_succeeded_at, GraphQL::Types::ISO8601DateTime, null: true
      field :last_published_at, GraphQL::Types::ISO8601DateTime, null: true
      field :last_error, String, null: true
      field :stale, Boolean, null: false
    end
  end
end
