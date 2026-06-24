# Adiciona os estados de lifecycle in_review/published ao protocol_definitions.
# C3 (refundação, Etapa 8): published ≠ active. `active` continua sendo o estado
# de vigência per-cidade, garantido pela unique parcial WHERE status='active'
# (já existente — idx_protocol_definitions_one_active_per_name_muni).
#
# protocol_definitions pertence a rota_admin (ADR-0019, ver
# 20260620000020_enable_rls_on_data_plane). Operações que exigem ownership
# (ADD/DROP CONSTRAINT) precisam rodar via conexão rota_admin, não rota_app.
class ProtocolLifecycleStates < ActiveRecord::Migration[8.0]
  def up
    as_admin do |c|
      c.exec("ALTER TABLE protocol_definitions DROP CONSTRAINT ck_protocol_definitions_status")
      c.exec(<<~SQL)
        ALTER TABLE protocol_definitions
          ADD CONSTRAINT ck_protocol_definitions_status
          CHECK (status IN ('draft','in_review','published','active','retired'))
      SQL
    end
  end

  def down
    # Reversível: requer que nenhuma linha esteja em in_review/published.
    as_admin do |c|
      c.exec("ALTER TABLE protocol_definitions DROP CONSTRAINT ck_protocol_definitions_status")
      c.exec(<<~SQL)
        ALTER TABLE protocol_definitions
          ADD CONSTRAINT ck_protocol_definitions_status
          CHECK (status IN ('draft','active','retired'))
      SQL
    end
  end

  private

  # DDL de ownership roda como rota_admin (BYPASSRLS, dono das tabelas do data
  # plane). Mesmo padrão de 20260620000020_enable_rls_on_data_plane.
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
