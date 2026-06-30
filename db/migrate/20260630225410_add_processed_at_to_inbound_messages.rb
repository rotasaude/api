class AddProcessedAtToInboundMessages < ActiveRecord::Migration[8.1]
  def up
    as_admin do |c|
      c.exec("ALTER TABLE inbound_messages ADD COLUMN processed_at timestamptz")
      c.exec("CREATE INDEX idx_inbound_messages_unprocessed ON inbound_messages (created_at) WHERE processed_at IS NULL")
    end
  end

  def down
    as_admin do |c|
      c.exec("DROP INDEX IF EXISTS idx_inbound_messages_unprocessed")
      c.exec("ALTER TABLE inbound_messages DROP COLUMN processed_at")
    end
  end

  private

  # inbound_messages é owned por rota_admin; DDL exige esse papel.
  # Mesmo padrão de 20260630215915_allow_aborted_by_cancellation_triage_status.
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
