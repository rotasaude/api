# Rastreio por lote (contrato §5): membros do laboratório e admin; sem nome
# de paciente; cada leitura grava lab_supply_lot.traced (só ids; Desvio 14).
# Lote de outro laboratório: 404 (C-E27).
require "csv"

module Lab
  module Inventory
    class TracesController < BaseController
      before_action :load_lot

      def show
        render json: Trace.call(lot: @lot)
      end

      def csv
        data = Trace.call(lot: @lot)
        body = CSV.generate do |out|
          out << Trace::CSV_HEADERS
          data[:results].each { |r| out << [ "resultado", r[:requisition_number], r[:sigtap_code], r[:entered_at] ] }
          data[:qc_values].each { |v| out << [ "controle", v[:run_id], v[:analyte_key], v[:entered_at] ] }
        end
        send_data body, type: "text/csv; charset=utf-8", disposition: "attachment", filename: "rastreio-lote-#{@lot.lot_number.parameterize}.csv"
      end

      private

      def load_lot
        @lot = uuid?(params[:id]) && LabSupplyLot.includes(:lab_supply).find_by(id: params[:id])
        return not_found unless @lot && reader?(@lot.lab_supply.exam_provider_id)

        DomainEvents.publish(
          "lab_supply_lot.traced",
          lab_supply_lot_id: @lot.id, user_id: Current.user.id
        )
      end
    end
  end
end
