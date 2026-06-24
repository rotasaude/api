# Rename PT → EN do núcleo de triagem (C1, refundação Etapa 9).
#   triagens → triages
#   report_snapshots.triagem_id → triage_id
#   eventos históricos triagem.* → triage.* em domain_events
#
# NOTA — exceção autorizada à imutabilidade de `domain_events`: o ADR de auditoria
# (0004/0014) define domain_events como append-only (único UPDATE legítimo é
# published_at). O autor autorizou explicitamente (Etapa 9) migrar os NOMES de
# eventos históricos PT → EN. Esta é a única exceção; deve ser registrada no ADR.
class RenameTriagensToTriages < ActiveRecord::Migration[8.0]
  def up
    rename_table :triagens, :triages
    rename_column :report_snapshots, :triagem_id, :triage_id

    execute "UPDATE domain_events SET name = 'triage.completed' WHERE name = 'triagem.completed'"
    execute "UPDATE domain_events SET name = 'triage.urgent'    WHERE name = 'triagem.urgent'"
  end

  def down
    execute "UPDATE domain_events SET name = 'triagem.urgent'    WHERE name = 'triage.urgent'"
    execute "UPDATE domain_events SET name = 'triagem.completed' WHERE name = 'triage.completed'"
    rename_column :report_snapshots, :triage_id, :triagem_id
    rename_table :triages, :triagens
  end
end
