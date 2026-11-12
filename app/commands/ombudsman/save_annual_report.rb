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
    # A linha de rascunho do ano (criada se falta), com o horário `now`.
    def draft_for(year, now)
      OmbudsmanAnnualReport.create_or_find_by!(year: year) do |report|
        report.state = "draft"
        report.created_at = now
        report.updated_at = now
      end
    end

    def call(year:, attrs:, now: Time.current)
      attrs = attrs.to_h.stringify_keys
      unknown = (attrs.keys - KEYS).first
      return Input.refuse(unknown.to_s[0, BaseController::KEY_PATH_MAX]) if unknown

      values = {}
      attrs.each do |key, value|
        return Input.refuse(key) unless value.nil? || (value.is_a?(String) && value.strip.length <= Catalog::REPORT_TEXT_MAX)

        values[key] = value&.strip.presence
      end

      OmbudsmanAnnualReport.transaction(requires_new: true) do
        report = draft_for(year, now)
        report.lock!
        next Result.fail(:report_published) if report.published?

        if values.any?
          report.assign_attributes(values.merge("updated_at" => now))
          report.save!(touch: false) # um `updated_at` igual ao antigo não é mudança: sem touch:false o relógio o sobrescreve
        end
        Result.ok(report: report)
      end
    end
  end
end
