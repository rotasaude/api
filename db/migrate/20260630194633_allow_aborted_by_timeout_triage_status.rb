class AllowAbortedByTimeoutTriageStatus < ActiveRecord::Migration[8.1]
  def up
    as_admin do |c|
      c.exec("ALTER TABLE triages DROP CONSTRAINT ck_triagens_status")
      c.exec("ALTER TABLE triages ADD CONSTRAINT ck_triagens_status CHECK (status IN ('in_progress','completed','aborted_by_revocation','aborted_by_timeout'))")
    end
  end

  def down
    as_admin do |c|
      c.exec("ALTER TABLE triages DROP CONSTRAINT ck_triagens_status")
      c.exec("ALTER TABLE triages ADD CONSTRAINT ck_triagens_status CHECK (status IN ('in_progress','completed','aborted_by_revocation'))")
    end
  end

  private

  # DDL de ownership exige rota_admin. Mesmo padrão de
  # 20260623000020_rename_triagens_to_triages.
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
