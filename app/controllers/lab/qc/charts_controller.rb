# GET /lab/qc/chart (contrato §3; spec §8; C-E5): liberador ligado, RT/substituto
# ou admin; from/to opcionais (padrão: últimos 31 dias; no máximo 366). Sem trilha.
module Lab
  module Qc
    class ChartsController < BaseController
      DATE = /\A\d{4}-\d{2}-\d{2}\z/
      DEFAULT_DAYS = 31
      MAX_DAYS = 366

      def show
        level = params[:level]
        analyte_key = params[:analyte_key]
        return render_failure(Result.fail(:filter_required)) unless uuid?(params[:lot_id]) && uuid?(params[:instrument_id]) &&
                                                                    level.is_a?(String) && level.present? &&
                                                                    analyte_key.is_a?(String) && analyte_key.present?
        # C-E36: UUID desconhecido ou de outro laboratório → 404; papel insuficiente no próprio → 403.
        lot = LabQcLot.find_by(id: params[:lot_id])
        instrument = LabInstrument.find_by(id: params[:instrument_id])
        return not_found unless lot && instrument && reader?(lot.lab_qc_material.exam_provider_id)

        provider_id = lot.lab_qc_material.exam_provider_id
        return not_found unless instrument.exam_provider_id == provider_id
        return forbid unless releaser?(provider_id)

        from = date_param(:from)
        to = date_param(:to)
        return render_failure(Result.fail(:invalid_date)) if from == :invalid || to == :invalid

        to ||= Time.zone.today
        from ||= to - DEFAULT_DAYS
        return render_failure(Result.fail(:invalid_period)) if from > to || (to - from) > MAX_DAYS

        render json: Chart.call(lot: lot, level: level, analyte_key: analyte_key, instrument: instrument,
                                from: from.beginning_of_day, to: to.end_of_day)
      end

      private

      # nil: ausente; :invalid: fora do formato ou inexistente.
      def date_param(key)
        raw = params[key]
        return nil if raw.blank?
        return :invalid unless raw.is_a?(String) && raw.match?(DATE)

        Date.iso8601(raw)
      rescue Date::Error
        :invalid
      end
    end
  end
end
