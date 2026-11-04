# Parâmetros do CAPS da cidade (ADR 0049): uma linha só (id 1, CHECK) — os
# limites do acolhimento noturno por modalidade (night_limits) e o prazo de
# revisão do PTS. A migração a insere; o banco carregado do dump nasce sem ela
# (ensure_defaults!). Nunca é apagada (trigger).
class PsychosocialSetting < ApplicationRecord
  self.primary_key = "id"

  belongs_to :updated_by_user, class_name: "User", optional: true

  def self.current = find_by(id: 1) || (ensure_defaults! && find(1))

  # A linha com os padrões do banco se falta; nunca mexe na gravada.
  def self.ensure_defaults!(now: Time.current)
    insert_all([ { "id" => 1, "updated_at" => now } ], unique_by: :id)
    true
  end
end
