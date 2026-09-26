# ReportSnapshot imutável (ADR 0010; verificação do módulo 04). Só trigger, sem
# mudança de tabela: o dump db/city_schema.rb não o representa, então ele vem
# de db/city_triggers.sql — a mesma fonte que load_city_schema executa depois
# de carregar o dump (bancos de teste e dev) e que esta migração executa nos
# bancos de cidade já existentes (rollout: city:migrate:all).
class GuardReportSnapshots < ActiveRecord::Migration[8.1]
  def up
    execute File.read(Rails.root.join("db/city_triggers.sql"))
  end

  def down
    execute "DROP TRIGGER IF EXISTS report_snapshots_immutable ON report_snapshots"
    execute "DROP FUNCTION IF EXISTS rota_report_snapshot_guard()"
  end
end
