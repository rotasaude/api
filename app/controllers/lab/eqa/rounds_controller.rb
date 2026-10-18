# /lab/eqa (contrato §4; spec §8; C12): liberador ligado ao laboratório (RT
# incluso) ou admin; escrita com step-up. O PDF do relatório anual: envio
# (só PDF, até 10 MB, cifrado como os do 21a) e leitura. Sem trilha de
# leitura: o relatório anual do programa externo não tem dado de paciente.
module Lab
  module Eqa
    class RoundsController < Lab::Qc::BaseController
      before_action :require_step_up!, only: %i[create upload]
      before_action -> { provider!(allow: :releaser?) }, only: %i[index summary]
      before_action :load_round, only: %i[show annual_report]

      def index
        rounds = LabEqaRound.where(exam_provider_id: @provider.id)
        rounds = rounds.where(round_date: Date.new(params[:year].to_i, 1, 1)..Date.new(params[:year].to_i, 12, 31)) if params[:year].to_s.match?(/\A\d{4}\z/)
        render json: { rounds: rounds.includes(:recorded_by_user).order(round_date: :desc, created_at: :desc).limit(200).map { |r| Json.round(r) } }
      end

      def show = render(json: Json.round(@round))

      def annual_report
        file = @round.annual_report_file
        return not_found unless file

        send_data file.bytes, type: "application/pdf", disposition: "inline", filename: "ceq-#{@round.round_code.parameterize}-relatorio-anual.pdf"
      end

      def upload
        return forbid unless Lab::Access.releaser_provider_ids(Current.user).any? || Lab::Access.admin?(Current.user)
        return render_failure(Result.fail(:invalid_file)) unless params[:content_type] == "application/pdf"

        result = Exams::Files.store_base64(data: params[:data], content_type: "application/pdf", user: Current.user)
        return render_failure(result) if result.failure?

        render json: { upload_id: result.payload[:file].id }, status: :created
      end

      def create
        provider = lab_param
        return render_failure(Result.fail(:invalid_provider)) unless provider
        return forbid unless releaser?(provider.id)

        result = RecordRound.call(body_params, by: Current.user)
        return render_failure(result) if result.failure?

        render json: Json.round(result.payload[:round]), status: :created
      end

      def summary
        year = params[:year].to_s.match?(/\A\d{4}\z/) ? params[:year].to_i : Time.zone.today.year
        render json: Summary.call(provider_id: @provider.id, year: year)
      end

      private

      def load_round
        @round = uuid?(params[:id]) && LabEqaRound.find_by(id: params[:id])
        return not_found unless @round

        forbid unless releaser?(@round.exam_provider_id)
      end
    end
  end
end
