# Limpeza de trilha de auditoria commitada por exemplos sem transação.
# platform_events recusa DELETE dentro da retenção (db/platform_triggers.sql,
# F-07.11) e o papel da suíte (rota_platform) não pode desligar trigger. Só o
# superusuário do Postgres de teste pode — e só aqui, para apagar o que o
# próprio exemplo gravou. Nunca use fora de spec/.
module AuditCleanup
  extend self

  def delete_platform_events!(where_sql, *binds)
    conn = PG.connect(
      host: ENV.fetch("DATABASE_HOST", "127.0.0.1"), port: ENV.fetch("DATABASE_PORT", "5432"),
      dbname: PlatformRecord.connection_db_config.database,
      user: "rota_saude", password: ENV.fetch("POSTGRES_PASSWORD", "postgres")
    )
    conn.transaction do |c|
      c.exec("SET LOCAL session_replication_role = replica")
      c.exec_params("DELETE FROM platform_events WHERE #{where_sql}", binds)
    end
  ensure
    conn&.close
  end
end

RSpec.configure do |config|
  config.include AuditCleanup
end
