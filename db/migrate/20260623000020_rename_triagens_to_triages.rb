# Rename PT → EN do núcleo de triagem (C1, refundação Etapa 9).
#   triagens → triages
#   report_snapshots.triagem_id → triage_id
#   eventos históricos triagem.* → triage.* em domain_events
#
# NOTA — exceção autorizada à imutabilidade de `domain_events`: o ADR de auditoria
# (0004/0014) define domain_events como append-only (único UPDATE legítimo é
# published_at). O autor autorizou explicitamente (Etapa 9) migrar os NOMES de
# eventos históricos PT → EN. Esta é a única exceção; deve ser registrada no ADR.
#
# triagens, report_snapshots e domain_events pertencem a rota_admin e têm FORCE
# ROW LEVEL SECURITY (ADR-0019, ver 20260620000020_enable_rls_on_data_plane):
#   - RENAME TABLE/COLUMN exige ownership → precisa de rota_admin.
#   - o UPDATE em domain_events precisa de rota_admin (BYPASSRLS), senão a política
#     tenant_isolation filtraria as linhas para 0 (não há app.municipality_id na migration).
# Reproduzimos aqui o que rename_table/rename_column fariam com os índices
# (prefixo index_<tabela>_* e <tabela>_pkey), para manter o schema.rb limpo.
class RenameTriagensToTriages < ActiveRecord::Migration[8.0]
  def up
    as_admin do |c|
      c.exec("ALTER TABLE triagens RENAME TO triages")
      c.exec("ALTER INDEX triagens_pkey RENAME TO triages_pkey")
      c.exec("ALTER INDEX index_triagens_on_conversation_id_and_created_at RENAME TO index_triages_on_conversation_id_and_created_at")
      c.exec("ALTER INDEX index_triagens_on_conversation_id_and_status RENAME TO index_triages_on_conversation_id_and_status")
      c.exec("ALTER INDEX index_triagens_on_conversation_id RENAME TO index_triages_on_conversation_id")
      c.exec("ALTER INDEX index_triagens_on_municipality_id RENAME TO index_triages_on_municipality_id")
      c.exec("ALTER INDEX index_triagens_on_protocol_definition_id RENAME TO index_triages_on_protocol_definition_id")
      c.exec("ALTER INDEX index_triagens_on_status RENAME TO index_triages_on_status")
      c.exec("ALTER INDEX index_triagens_on_tier RENAME TO index_triages_on_tier")

      c.exec("ALTER TABLE report_snapshots RENAME COLUMN triagem_id TO triage_id")
      c.exec("ALTER INDEX index_report_snapshots_on_triagem_id RENAME TO index_report_snapshots_on_triage_id")

      c.exec("UPDATE domain_events SET name = 'triage.completed' WHERE name = 'triagem.completed'")
      c.exec("UPDATE domain_events SET name = 'triage.urgent'    WHERE name = 'triagem.urgent'")
    end
  end

  def down
    as_admin do |c|
      c.exec("UPDATE domain_events SET name = 'triagem.urgent'    WHERE name = 'triage.urgent'")
      c.exec("UPDATE domain_events SET name = 'triagem.completed' WHERE name = 'triage.completed'")

      c.exec("ALTER INDEX index_report_snapshots_on_triage_id RENAME TO index_report_snapshots_on_triagem_id")
      c.exec("ALTER TABLE report_snapshots RENAME COLUMN triage_id TO triagem_id")

      c.exec("ALTER INDEX index_triages_on_tier RENAME TO index_triagens_on_tier")
      c.exec("ALTER INDEX index_triages_on_status RENAME TO index_triagens_on_status")
      c.exec("ALTER INDEX index_triages_on_protocol_definition_id RENAME TO index_triagens_on_protocol_definition_id")
      c.exec("ALTER INDEX index_triages_on_municipality_id RENAME TO index_triagens_on_municipality_id")
      c.exec("ALTER INDEX index_triages_on_conversation_id RENAME TO index_triagens_on_conversation_id")
      c.exec("ALTER INDEX index_triages_on_conversation_id_and_status RENAME TO index_triagens_on_conversation_id_and_status")
      c.exec("ALTER INDEX index_triages_on_conversation_id_and_created_at RENAME TO index_triagens_on_conversation_id_and_created_at")
      c.exec("ALTER INDEX triages_pkey RENAME TO triagens_pkey")
      c.exec("ALTER TABLE triages RENAME TO triagens")
    end
  end

  private

  # DDL/DML de ownership/BYPASSRLS roda como rota_admin. Mesmo padrão de
  # 20260620000020_enable_rls_on_data_plane.
  def as_admin
    require "pg"

    conn = PG.connect(
      host: ENV.fetch("DATABASE_HOST", "127.0.0.1"),
      port: ENV.fetch("DATABASE_PORT", 5432),
      dbname: connection.current_database,
      user: "rota_admin",
      password: ENV.fetch("ROTA_ADMIN_PASSWORD", "rota_admin")
    )

    yield conn
  ensure
    conn&.close
  end
end
