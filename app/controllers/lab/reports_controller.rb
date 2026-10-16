# Laudos do laboratório (contrato §5): PDF e retificação.
module Lab
  class ReportsController < BaseController
    before_action :load_report

    # URL curta do PDF (A4 do 21a): a trilha é gravada no download
    # (Exams::FilesController, access lab_report), não aqui.
    def pdf
      return not_found unless @report.pdf_file

      render json: { pdf_url: Exams::Files.url_for(@report.pdf_file, user: Current.user) }
    end

    CHANNELS = LabCriticalNotice::CHANNELS
    MAX_CONTACTS = 10

    # Contrato §5 (RDC 978 art. 170): laudo novo com motivo e quem foi avisado.
    # Motivo e contatos são conferidos antes do Lab::Release, que confere os
    # itens (B42: só itens deste laudo) antes do TOTP — recusa nunca queima o
    # código. Nomes de contato e motivo só no laudo (cifrados), nunca em log.
    def rectify
      return render_failure(Result.fail(:invalid_transition, details: { status: @report.status })) unless @report.status == "released"

      reason = params[:reason].is_a?(String) ? params[:reason].strip : ""
      return render_failure(Result.fail(:reason_required)) unless reason.length.between?(3, 500)

      contacts = rectification_contacts
      return render_failure(Result.fail(:contacts_required)) unless contacts

      result = Lab::Release.call(requisition: @report.lab_requisition, item_ids: params[:item_ids], signature: params[:signature],
                                 totp: params[:totp], by: Current.user, rectifies: @report, reason: reason, contacts: contacts)
      return render_failure(result) if result.failure?

      render json: Lab::Json.report_summary(result.payload[:report], viewer: Current.user), status: :created
    end

    private

    # 1 a 10 contatos { person, channel, at }; qualquer um fora da forma → nil.
    def rectification_contacts
      raw = params[:contacts]
      raw = raw.map { |c| c.respond_to?(:to_unsafe_h) ? c.to_unsafe_h : c } if raw.is_a?(Array)
      return nil unless raw.is_a?(Array) && raw.size.between?(1, MAX_CONTACTS)

      raw.map do |c|
        return nil unless c.is_a?(Hash)

        person = c["person"].is_a?(String) ? c["person"].strip : ""
        at = begin
          Time.iso8601(c["at"].to_s)
        rescue ArgumentError
          nil
        end
        return nil unless person.length.between?(1, 120) && CHANNELS.include?(c["channel"]) && at

        { "person" => person, "channel" => c["channel"], "at" => at.iso8601 }
      end
    end

    def load_report
      @report = uuid?(params[:id]) && LabReport.find_by(id: params[:id])
      return not_found unless @report

      forbid unless Lab::Access.member?(Current.user, @report.exam_provider_id)
    end
  end
end
