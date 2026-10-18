# /lab/eqa (contrato §4; spec §8; C12): liberador ligado ao laboratório (RT
# incluso) ou admin; escrita com step-up. O PDF do relatório anual: envio
# (só PDF, até 10 MB, cifrado como os do 21a) e leitura. Sem trilha de
# leitura: o relatório anual do programa externo não tem dado de paciente.
module Lab
  module Eqa
    class RoundsController < Lab::Qc::BaseController
      before_action :require_step_up!, only: %i[create upload create_annual_report]
      before_action -> { provider!(allow: :releaser?) }, only: %i[index summary annual_reports]
      before_action :load_round, only: %i[show]

      def index
        rounds = LabEqaRound.where(exam_provider_id: @provider.id)
        rounds = rounds.where(round_date: Date.new(params[:year].to_i, 1, 1)..Date.new(params[:year].to_i, 12, 31)) if params[:year].to_s.match?(/\A\d{4}\z/)
        render json: { rounds: rounds.includes(:recorded_by_user).order(round_date: :desc, created_at: :desc).limit(200).map { |r| Json.round(r) } }
      end

      def show = render(json: Json.round(@round))

      def annual_reports
        year = params[:year].to_s.match?(/\A\d{4}\z/) ? params[:year].to_i : nil
        reports = LabEqaAnnualReport.where(exam_provider_id: @provider.id)
        reports = reports.where(year: year) if year
        render json: { annual_reports: reports.includes(:recorded_by_user).order(year: :desc, program: :asc).limit(200).map { |r| Json.annual_report(r) } }
      end

      def annual_report_pdf
        report = uuid?(params[:id]) && LabEqaAnnualReport.find_by(id: params[:id])
        return not_found unless report
        return not_found unless releaser?(report.exam_provider_id)

        send_data report.file.bytes, type: "application/pdf", disposition: "inline",
                                     filename: "ceq-#{report.program.parameterize}-#{report.year}-relatorio-anual.pdf"
      end

      def create_annual_report
        provider = lab_param
        return render_failure(Result.fail(:invalid_provider)) unless provider
        return forbid unless releaser?(provider.id)

        result = RecordAnnualReport.call(body_params, by: Current.user)
        return render_failure(result) if result.failure?

        render json: Json.annual_report(result.payload[:report]), status: :created
      end

      def upload
        return forbid unless Lab::Access.releaser_provider_ids(Current.user).any? || Lab::Access.admin?(Current.user)
        return render_failure(Result.fail(:invalid_file)) unless params[:content_type] == "application/pdf"

        result = Exams::Files.store_base64(data: params[:data], content_type: "application/pdf", user: Current.user, purpose: LabEqaAnnualReport::PURPOSE)
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

        not_found unless releaser?(@round.exam_provider_id)
      end
    end
  end
end
