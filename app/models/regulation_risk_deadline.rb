# Prazo em dias de cada cor de risco (ADR 0044). Uma linha por cor; a migração
# insere os padrões e nada apaga (trigger).
class RegulationRiskDeadline < ApplicationRecord
  self.primary_key = "color"

  belongs_to :updated_by_user, class_name: "User", optional: true

  # Os padrões de CareRegulation::Catalog nas cores que faltam (o banco
  # carregado do dump nasce sem linha; a migração as insere). Não mexe em
  # prazo já gravado.
  def self.ensure_defaults!(now: Time.current)
    rows = CareRegulation::Catalog::DEFAULT_DEADLINE_DAYS.map { |color, days| { color: color, days: days, updated_at: now } }
    insert_all(rows, unique_by: :color)
  end
end
