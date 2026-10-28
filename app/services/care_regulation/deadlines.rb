# Prazo em dias de cada cor de risco (ADR 0044; contrato §6). Cor sem linha na
# cidade (banco carregado do dump nasce sem) cai em
# Catalog::DEFAULT_DEADLINE_DAYS: nunca erro, nunca nil.
module CareRegulation
  module Deadlines
    module_function

    def days(color)
      default = Catalog::DEFAULT_DEADLINE_DAYS.fetch(color)
      RegulationRiskDeadline.where(color: color).pick(:days) || default
    end

    # Data do pedido no fuso da cidade + dias da cor.
    def due_on(requested_at:, color:) = requested_at.in_time_zone.to_date + days(color)

    # { "red" => 7, "yellow" => 30, "green" => 90, "blue" => 180 }, em ordem de gravidade.
    def all
      stored = RegulationRiskDeadline.pluck(:color, :days).to_h
      Catalog::COLORS.index_with { |color| stored.fetch(color) { Catalog::DEFAULT_DEADLINE_DAYS.fetch(color) } }
    end
  end
end
