# POST /ombudsman/annual_reports/:year/publish (ADR 0051; contrato §11; §16
# Q27): grava a foto dos números do ano inteiro (Ombudsman::Panel, com a mesma
# supressão) e congela o relatório (trigger). Só ano encerrado, no fuso da
# cidade: o corrente ou futuro → 422 `year_not_closed`. Já publicado → 409
# `already_published`. Sem rascunho prévio publica com os textos vazios.
module Ombudsman
  module PublishAnnualReport
    module_function

    # -> Result.ok(report:) | fail(:year_not_closed) | fail(:already_published)
    def call(year:, by:, today: Time.zone.today, now: Time.current)
      return Result.fail(:year_not_closed) if year >= today.year

      OmbudsmanAnnualReport.transaction(requires_new: true) do
        report = SaveAnnualReport.draft_for(year, now)
        report.lock!
        next Result.fail(:already_published) if report.published?

        snapshot = Panel.call(from: Date.new(year, 1, 1), to: Date.new(year, 12, 31), today: today)
        report.update!(state: "published", snapshot: snapshot, published_at: now, published_by_user: by, updated_at: now)
        Result.ok(report: report)
      end
    end
  end
end
