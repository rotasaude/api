# Relatório de conferência (contrato §5, A11): municipal_admin ou regulador.
# Só leitura e sem dado de paciente: sem step-up.
require "csv"

module Exams
  class ReportsController < BaseController
    before_action { forbid("missing_role") unless Exams::Access.regulator?(Current.user) }
    before_action :load_month
    before_action :check_provider_id

    def show
      render json: { rows: Exams::Report.rows(month: @month, provider_id: provider_id) }
    end

    def csv
      body = CSV.generate do |out|
        if params[:detail] == "true"
          out << Exams::Report::DETAIL_HEADERS
          Exams::Report.detail(month: @month, provider_id: provider_id).each { |row| out << row }
        else
          out << Exams::Report::SUMMARY_HEADERS
          Exams::Report.rows(month: @month, provider_id: provider_id).each do |row|
            out << [ Exams::Report.safe_cell(row[:provider][:name]), *row.values_at(:authorized, :collected, :resulted_on_time, :resulted_late, :pending) ]
          end
        end
      end
      send_data body, type: "text/csv; charset=utf-8", disposition: "attachment", filename: "conferencia-exames-#{params[:month]}.csv"
    end

    private

    def provider_id = params[:provider_id].presence

    def check_provider_id
      return if provider_id.nil? || uuid?(provider_id)

      render json: { error: "invalid_filter" }, status: :unprocessable_entity
    end

    def load_month
      @month = Exams::Report.month_range(params[:month])
      render(json: { error: "invalid_month" }, status: :unprocessable_entity) unless @month
    end
  end
end
