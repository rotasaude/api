# Módulo 24b (ADR 0052; revisão final A-M1, A-M2, A-I1; Q67): índices da visita
# domiciliar e o guard de INSERT da visita.
#   - home_visit_days (team_id, day, sequence, id): as listas da equipe
#     (GET /home_visits/days e /home_visits, ordem day, sequence, id DESC) e o
#     GET /home_visits/count, lido a cada minuto (Q16); o único índice
#     composto começava por professional_id;
#   - home_visits (patient_id): a retenção da exclusão LGPD
#     (Citizens::RequestErasure/Erase); o índice por paciente que existe é
#     parcial (withdrawn_at IS NULL AND outcome = 1).
# Sem CONCURRENTLY (nenhuma migração de cidade usa; nota do runbook, Q67(3)).
# Reexecuta db/city_triggers.sql (o dump não representa trigger): o banco já
# migrado até a 900004 ganha o home_visits_insert_guard (a visita só entra em
# folha aberta). Irreversível.
class AddHomeVisitIndexes < ActiveRecord::Migration[8.1]
  def up
    add_index :home_visit_days, %i[team_id day sequence id], name: "idx_home_visit_days_team"
    add_index :home_visits, :patient_id, name: "idx_home_visits_patient"
    execute File.read(Rails.root.join("db/city_triggers.sql"))
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
