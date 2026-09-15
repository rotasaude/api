# Bancos descartáveis criados de verdade por specs que precisam de DDL comitado,
# de pg_dump ou de um banco que ainda não tem schema (Plano 4). Criados e apagados
# com a credencial de superusuário de bootstrap e SEMPRE com o prefixo PREFIX —
# nunca um banco da suíte, de dev ou de plataforma.
#
# Quem usa precisa de `self.use_transactional_tests = false` (DDL dentro da
# transação de fixture seria desfeito e invisível a outra conexão) e de apagar o
# banco no `after`.
module ScratchDatabases
  PREFIX = "rota_saude_test_scratch_"

  module_function

  def new_name
    "#{PREFIX}#{SecureRandom.hex(4)}"
  end

  def url(name)
    CityDatabaseUrls.city_database_url(name)
  end

  def create!(name)
    guard!(name)
    superuser { |conn| conn.exec("CREATE DATABASE #{PG::Connection.quote_ident(name)}") }
    name
  end

  def drop!(name)
    guard!(name)
    superuser { |conn| conn.exec("DROP DATABASE IF EXISTS #{PG::Connection.quote_ident(name)} WITH (FORCE)") }
  end

  def exists?(name)
    superuser { |conn| conn.exec_params("SELECT 1 FROM pg_database WHERE datname = $1", [ name ]).ntuples == 1 }
  end

  def superuser(database = "postgres")
    conn = PG.connect(CityDatabaseUrls.city_database_url(database))
    conn.set_notice_receiver { |_| }
    yield conn
  ensure
    conn&.close
  end

  def guard!(name)
    return if name.to_s.start_with?(PREFIX)

    raise ArgumentError, "scratch database must start with #{PREFIX}: #{name.inspect}"
  end
end
