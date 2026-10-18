# /lab/inventory/in_use (contrato §5): lotes em uso do aparelho (corrente);
# marcar lote em uso: membro do laboratório ou admin. Aparelho ou lote de
# outro laboratório: 404 (C-E27, como o desconhecido). O mesmo lote já em
# uso: 200 com o registro atual, nada criado (C-E6).
module Lab
  module Inventory
    class InUseController < BaseController
      PRELOAD = [ :lab_exam, { lab_supply_lot: :lab_supply } ].freeze

      def index
        instrument = uuid?(params[:instrument_id]) && LabInstrument.find_by(id: params[:instrument_id])
        return not_found unless instrument && reader?(instrument.exam_provider_id)

        rows = LabSupplyInUse.current.where(lab_instrument_id: instrument.id).includes(*PRELOAD).order(:started_at, :id)
        render json: { in_use: rows.map { |u| Json.in_use(u) } }
      end

      def create
        lot = uuid?(params[:lot_id]) && LabSupplyLot.includes(:lab_supply).find_by(id: params[:lot_id])
        return not_found unless lot && reader?(lot.lab_supply.exam_provider_id)

        result = SetInUse.call(lot_id: lot.id, instrument_id: params[:instrument_id], lab_exam_id: params[:lab_exam_id], by: Current.user)
        return render_failure(result) if result.failure?

        render json: Json.in_use(result.payload[:in_use]), status: result.payload[:created] ? :created : :ok
      end
    end
  end
end
