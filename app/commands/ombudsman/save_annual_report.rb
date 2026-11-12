# PATCH /ombudsman/annual_reports/:year (ADR 0051; contrato §11; §16 Q35): grava o
# rascunho do relatório de gestão do ano (cria a linha na primeira vez). Só as
# chaves recurring_problems, actions_taken e notes; cada uma nil (limpa) ou
# texto de até 8000, sem as bordas (vazio vira nil). Texto simples, não
# cifrado: é documento público. Publicado → 409 `report_published`.
module Ombudsman
  module SaveAnnualReport
    KEYS = %w[recurring_problems actions_taken notes].freeze

    module_function

    # -> Result.ok(report:) | fail(:invalid_request, details: { path:, problems: }) | fail(:report_published)
    def call(year:, attrs:)
      attrs = attrs.to_h.stringify_keys
      unknown = (attrs.keys - KEYS).first
      return Input.refuse(unknown.to_s[0, BaseController::KEY_PATH_MAX]) if unknown

      values = {}
      attrs.each do |key, value|
        return Input.refuse(key) unless value.nil? || (value.is_a?(String) && value.strip.length <= Catalog::REPORT_TEXT_MAX)

        values[key] = value&.strip.presence
      end

      OmbudsmanAnnualReport.transaction(requires_new: true) do
        report = OmbudsmanAnnualReport.create_or_find_by!(year: year) { |new_report| new_report.state = "draft" }
        report.lock!
        next Result.fail(:report_published) if report.published?

        report.update!(values) if values.any?
        Result.ok(report: report)
      end
    end
  end
end
