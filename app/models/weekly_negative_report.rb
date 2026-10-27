# Negativa semanal da unidade (ADR 0043): "nenhum caso nesta semana". Só
# acréscimo (trigger); week é a semana epidemiológica ("2026-42"), conferida
# pelo CHECK do banco e pelo Surveillance::EpiWeek.
class WeeklyNegativeReport < ApplicationRecord
  belongs_to :health_unit
  belongs_to :recorded_by_user, class_name: "User"
end
