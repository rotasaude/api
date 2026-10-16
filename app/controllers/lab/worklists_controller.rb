module Lab
  class WorklistsController < BaseController
    before_action :provider_param!
    before_action :lab_member!
    before_action :load_filters

    def show = render(json: { groups: Lab::Worklist.groups(provider: @provider, filters: @filters) })

    def pdf
      response.headers["Cache-Control"] = "no-store"
      send_data Lab::WorklistPdf.call(Lab::Worklist.groups(provider: @provider, filters: @filters), provider: @provider),
                type: "application/pdf", disposition: "inline", filename: "mapa-de-trabalho.pdf"
    end

    private

    # Tem nome de paciente: só a equipe daquele laboratório (não admin, não UBS).
    def lab_member! = (forbid unless Lab::Access.member?(Current.user, @provider.id))

    def load_filters
      date = params[:date].present? ? (Date.iso8601(params[:date].to_s) rescue :invalid) : nil
      sector = params[:sector].presence
      return render(json: { error: "invalid_filter" }, status: :unprocessable_entity) if date == :invalid || (sector && !LabExam::SECTORS.include?(sector))

      @filters = { sector: sector, bench: params[:bench].presence, urgent: params[:urgent] == "true", pending: params[:pending] == "true", date: date }
    end
  end
end
