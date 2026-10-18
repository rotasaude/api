# /lab/inventory/consumption (contrato §5): membros do laboratório e admin;
# sem dado de paciente; só leitura (sem trilha); JSON e CSV. O mês é AAAA-MM
# (validado pela data ISO do primeiro dia); outro laboratório: 403.
require "csv"

module Lab
  module Inventory
    class ConsumptionController < BaseController
      before_action -> { provider! }
      before_action :load_month

      def show = render(json: { rows: Consumption.call(provider_id: @provider.id, month: @month) })

      def csv
        names = LabInstrument.where(exam_provider_id: @provider.id).pluck(:id, :name).to_h
        body = CSV.generate do |out|
          out << Consumption::HEADERS
          Consumption.call(provider_id: @provider.id, month: @month).each do |r|
            out << [ Exams::Report.safe_cell(r[:name]), r[:instrument_id] ? Exams::Report.safe_cell(names[r[:instrument_id]]) : "total",
                     r[:tests_performed], r[:tests_opened], r[:deviation_pct]&.to_s&.tr(".", ",") ]
          end
        end
        send_data body, type: "text/csv; charset=utf-8", disposition: "attachment", filename: "consumo-#{@month.strftime('%Y-%m')}.csv"
      end

      private

      def load_month
        text = params[:month].to_s
        @month = text.match?(/\A\d{4}-\d{2}\z/) ? ClinicalDocuments::IsoDate.parse("#{text}-01") : nil
        render_failure(Result.fail(:invalid_month)) unless @month
      end
    end
  end
end
