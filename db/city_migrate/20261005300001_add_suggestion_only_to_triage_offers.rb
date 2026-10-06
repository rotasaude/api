# "Só por sugestão" na linha do catálogo da cidade (ADR 0027, revisão de
# 2026-10-05): o protocolo fica fora de "Disponíveis" e só começa a partir de
# uma sugestão pendente do par. Só expansão; o padrão mantém o comportamento.
class AddSuggestionOnlyToTriageOffers < ActiveRecord::Migration[8.1]
  def change
    add_column :triage_offers, :suggestion_only, :boolean, null: false, default: false
  end
end
