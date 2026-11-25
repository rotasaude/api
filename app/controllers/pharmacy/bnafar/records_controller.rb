# POST /pharmacy/bnafar/records/:id/correct (módulo 27b; contrato §3, §6; Q8,
# Q25): a correção da saída externa aceita, para a saída inteira, por PUT.
# Corpo `{ expected_version, exit_type?, destination_kind?, destination_code?,
# reason }`. `municipal_admin`, com step-up; exige o `bnafar`. Ordem: papel
# (403) → registro (404) → step-up (401) → o comando (409 not_correctable |
# correction_window_closed | external_exit_changed; 422 do corpo).
# Responde `{ records: [<registro>] }`, os registros novos; nunca o payload.
module Pharmacy
  module Bnafar
    class RecordsController < BaseController
      def correct
        return forbid unless admin?

        record = uuid?(params[:id]) ? BnafarRecord.find_by(id: params[:id]) : nil
        return not_found unless record

        require_step_up!
        return if performed?

        result = ::Bnafar::CorrectExit.call(record: record, attrs: body.except("expected_version"), expected_version: body_param("expected_version"),
                                            by: Current.user, now: Time.current)
        return render_failure(result) if result.failure?

        rows = BnafarRecord.includes(*::Bnafar::Json::RECORD_PRELOAD).where(id: result.payload.fetch(:records).map(&:id)).order(:created_at, :id).to_a
        labels = ::Bnafar::Json.labels(rows)
        render json: { records: rows.map { |row| ::Bnafar::Json.record(row, label_index: labels) } }
      end
    end
  end
end
