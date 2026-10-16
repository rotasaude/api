# Relatórios (contrato §6; D13): municipal_admin ou lab_releaser; só leitura,
# sem dado de paciente, sem step-up.
require "csv"

module Lab
  class ProductionReportsController < BaseController
    KINDS = %w[production rejections turnaround].freeze

    before_action :scope_providers
    before_action :load_month

    def show
      data = Lab::ProductionReport.public_send(kind, provider_ids: @provider_ids, month: @month)
      render json: data.is_a?(Hash) ? data : { rows: data }
    end

    def csv
      data = Lab::ProductionReport.public_send(kind, provider_ids: @provider_ids, month: @month)
      safe = ->(v) { Exams::Report.safe_cell(v) }
      body = CSV.generate do |out|
        case kind
        when "production"
          out << Lab::ProductionReport::PRODUCTION_HEADERS
          data[:rows].each { |r| out << [ safe.(r[:origin_unit][:name]), r[:sigtap_code], safe.(r[:exam_name]), r[:sector], safe.(r.dig(:releaser, :name)), r[:quantity], r[:sigtap_value_cents] ] }
        when "rejections"
          out << Lab::ProductionReport::REJECTION_HEADERS
          data.each { |r| out << [ safe.(r[:reason][:name]), safe.(r[:origin_unit][:name]), r[:count] ] }
        else
          out << Lab::ProductionReport::TURNAROUND_HEADERS
          data.each { |r| out << [ r[:sigtap_code], safe.(r[:exam_name]), r[:on_time], r[:late], r[:pending] ] }
        end
      end
      send_data body, type: "text/csv; charset=utf-8", disposition: "attachment", filename: "laboratorio-#{kind}-#{params[:month]}.csv"
    end

    private

    def kind = params[:kind]

    def scope_providers
      ids = Lab::Access.admin?(Current.user) ? Lab::Access.labs.pluck(:id) : Lab::Access.releaser_provider_ids(Current.user)
      return forbid if ids.empty?

      if params[:provider_id].present?
        return forbid unless ids.include?(params[:provider_id])

        ids = [ params[:provider_id] ]
      end
      @provider_ids = ids
    end

    def load_month
      @month = Exams::Report.month_range(params[:month])
      render(json: { error: "invalid_month" }, status: :unprocessable_entity) unless @month
    end
  end
end
