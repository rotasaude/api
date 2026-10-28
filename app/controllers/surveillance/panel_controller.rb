# Painel por bairro e semana epidemiológica (contrato §8, K7; papéis
# `surveillance` e `analyst`):
#   GET /surveillance/panel?from_week=AAAA-SS&to_week=AAAA-SS&disease=<código>
# Padrão: as 12 semanas até a anterior à corrente. Agregado sem nome de pessoa:
# sem trilha (não é leitura de prontuário). O resultado é um sinal para
# avaliar, nunca um diagnóstico.
module Surveillance
  class PanelController < BaseController
    before_action { forbid unless surveillance? || Current.user.has_role?("analyst") }

    def index
      return unless query_only!(:from_week, :to_week, :disease)

      last = parse_week(:to_week) { EpiWeek.current(Time.zone.today).pred }
      first = parse_week(:from_week) { last && last - (Panel::PANEL_DEFAULT_WEEKS - 1) }
      return render_error("invalid_week") if last.nil? || first.nil?

      disease = params[:disease]
      if params.key?(:disease) && !(disease.is_a?(String) && Diseases.find(disease))
        return render_error("invalid_disease")
      end
      return render_error("invalid_range") unless valid_range?(first, last)

      render json: Panel.call(from: first, to: last, disease: disease)
    end

    private

    # Semana informada (nil se malformada) ou o padrão do bloco.
    def parse_week(key)
      params.key?(key) ? EpiWeek.parse(params[key]) : yield
    end

    def valid_range?(first, last)
      first <= last && (last.starts_on - first.starts_on).to_i / 7 + 1 <= Panel::PANEL_MAX_WEEKS
    end
  end
end
