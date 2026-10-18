# POST /lab/qc/values (contrato §3): membro do laboratório do aparelho; valor
# como string com ponto (C-E9: vírgula ou outro formato → invalid_value).
module Lab
  module Qc
    class ValuesController < BaseController
      def create
        instrument = uuid?(params[:instrument_id]) && LabInstrument.find_by(id: params[:instrument_id])
        return not_found unless instrument
        return forbid unless Lab::Access.member?(Current.user, instrument.exam_provider_id)

        lot = uuid?(params[:lot_id]) && LabQcLot.find_by(id: params[:lot_id])
        return render_failure(Result.fail(:not_found)) unless lot

        value = Decimal.json(params[:value])
        return render_failure(Result.fail(:invalid_value)) unless value

        run_id = params[:run_id].presence
        return render_failure(Result.fail(:not_found)) if run_id && !uuid?(run_id)

        result = RecordValue.call(instrument: instrument, lot: lot, level: params[:level].to_s, analyte_key: params[:analyte_key].to_s,
                                  value: value, source: "typed", by: Current.user, run_id: run_id)
        return render_failure(result) if result.failure?

        payload = result.payload
        body = { value: Json.value(payload[:value]), run: Json.run(payload[:run].reload), block: payload[:block] && Json.block(payload[:block].reload) }
        body[:notice] = payload[:notice] if payload[:notice]
        render json: body, status: :created
      end
    end
  end
end
