# /lab/qc/rules (contrato §3; C-E4): leitura para membros e admin; mudar só
# RT/substituto, com step-up.
module Lab
  module Qc
    class RulesController < BaseController
      before_action :require_step_up!, only: :update
      before_action :load_instrument

      def show
        return forbid unless reader?(@instrument.exam_provider_id)

        key = params[:analyte_key].to_s
        render json: Json.rule(@instrument.id, key, LabQcRule.current_for(@instrument.id, key))
      end

      def update
        return forbid unless technical?(@instrument.exam_provider_id)

        result = SaveRules.call(instrument: @instrument, analyte_key: params[:analyte_key], rules: params[:rules],
                                justification: params[:justification], by: Current.user)
        return render_failure(result) if result.failure?

        rule = result.payload[:rule]
        render json: Json.rule(@instrument.id, rule.analyte_key, rule)
      end

      private

      def load_instrument
        @instrument = uuid?(params[:instrument_id]) && LabInstrument.find_by(id: params[:instrument_id])
        not_found unless @instrument
      end
    end
  end
end
