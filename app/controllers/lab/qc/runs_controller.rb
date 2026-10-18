# /lab/qc/runs (contrato §3): corridas do dia do aparelho (leitura, sem
# trilha: nada de paciente); abrir corrida a pedido (membro).
module Lab
  module Qc
    class RunsController < BaseController
      DATE = /\A\d{4}-\d{2}-\d{2}\z/

      before_action :load_instrument

      def index
        day = day_param
        return render_failure(Result.fail(:invalid_date)) unless day

        runs = LabQcRun.where(lab_instrument_id: @instrument.id, started_at: day.in_time_zone.all_day).order(:started_at, :created_at)
        render json: { runs: runs.map { |r| Json.run(r) } }
      end

      def create
        return forbid unless Lab::Access.member?(Current.user, @instrument.exam_provider_id)

        render json: Json.run(OpenRun.call(instrument: @instrument, by: Current.user).payload[:run]), status: :created
      end

      private

      def load_instrument
        @instrument = uuid?(params[:instrument_id]) && LabInstrument.find_by(id: params[:instrument_id])
        not_found unless @instrument && reader?(@instrument.exam_provider_id) # C-E36
      end

      # Sem data: hoje. Data fora do formato ou inexistente: nil (invalid_date).
      def day_param
        raw = params[:date]
        return Time.zone.today if raw.blank?
        return nil unless raw.is_a?(String) && raw.match?(DATE)

        Date.iso8601(raw)
      rescue Date::Error
        nil
      end
    end
  end
end
