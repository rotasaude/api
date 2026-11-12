# GET/PATCH /ombudsman/annual_reports/:year e POST …/publish (ADR 0051;
# contrato §11; §16 Q27, Q35): o relatório de gestão anual, só o ouvidor.
# GET sempre 200 (rascunho vazio, sem gravar, quando não há linha); `numbers` =
# o snapshot publicado ou o painel vivo do ano. Ano fora de AAAA (2000..2999)
# → 404.
module Ombudsman
  class AnnualReportsController < BaseController
    YEAR = /\A\d{4}\z/
    YEARS = (2000..2999)

    before_action :require_ombudsman_role!
    before_action :load_year

    def show
      return unless query_only!

      render_report(OmbudsmanAnnualReport.find_by(year: @year))
    end

    def update
      return unless body_keys!(SaveAnnualReport::KEYS)

      result = SaveAnnualReport.call(year: @year, attrs: body)
      return render_failure(result) if result.failure?

      render_report(result.payload[:report])
    end

    def publish
      return unless query_only!

      result = PublishAnnualReport.call(year: @year, by: Current.user)
      return render_failure(result) if result.failure?

      render_report(result.payload[:report])
    end

    private

    def load_year
      @year = params[:year].to_s.match?(YEAR) ? params[:year].to_i : nil
      not_found unless @year && YEARS.cover?(@year)
    end

    def render_report(report)
      published = report&.published?
      numbers = published ? report.snapshot : Panel.call(from: Date.new(@year, 1, 1), to: Date.new(@year, 12, 31), today: Time.zone.today)
      render json: { year: @year, state: report ? report.state : "draft",
                     recurring_problems: report&.recurring_problems, actions_taken: report&.actions_taken, notes: report&.notes,
                     numbers: numbers, published_at: (report.published_at if published) }
    end
  end
end
