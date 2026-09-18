module Maintenance
  module Types
    class CityOperationsType < BaseObject
      description "Sinais operacionais da cidade — metadado e contagem, nunca conteúdo de cidadão " \
                   "(payload de evento, conteúdo/assinatura de relatório, mensagem de exceção)."

      field :domain_events, [ Types::DomainEventType ], null: false
      field :report_snapshots, [ Types::ReportSnapshotType ], null: false
      field :dashboard_metrics, [ Types::DashboardMetricType ], null: false
      field :failed_jobs, [ Types::FailedJobType ], null: false
    end
  end
end
