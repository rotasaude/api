# Banco e role de uma cidade no Postgres (spec banco-por-cidade §4, Plano 4).
#
# Tudo o que conecta aqui conecta como rota_provisioner — CREATEDB e CREATEROLE,
# sem superusuário — por PROVISIONER_DATABASE_URL. Em produção só o worker recebe
# essa URL: o processo web não cria nem apaga banco. url_for não conecta nem lê
# essa URL (o web a chama no POST /cities): monta a URL da cidade com
# CITY_DATABASE_HOST/PORT/SSLMODE, que não são secretos.
#
# Cada cidade tem um role próprio, DONO do seu banco, usado em runtime e nas
# migrations. O CONNECT de PUBLIC é revogado: o role de uma cidade (e rota_app)
# não abre o banco de outra. rota_provisioner vira membro de cada role de cidade —
# no Postgres 16 quem cria um role não herda os privilégios dele, e sem essa
# associação não poderia dar o banco a esse dono nem apagá-lo depois.
#
# A senha do role vai cifrada (SCRAM) no SQL, nunca em texto. Nomes derivam do
# slug, passam por quote_ident, e o slug precisa ser rótulo DNS de até
# MAX_SLUG_LENGTH caracteres, para o nome caber nos 63 bytes de identificador.
class CityDatabase
  class InvalidSlug < ArgumentError; end
  class ProvisionerMissing < StandardError; end
  class ConfigMissing < StandardError; end

  MAX_SLUG_LENGTH = 40
  SLUG = /\A[a-z0-9]([a-z0-9-]*[a-z0-9])?\z/

  class << self
    def valid_slug?(slug)
      slug.is_a?(String) && slug.length.between?(2, MAX_SLUG_LENGTH) && slug.match?(SLUG) &&
        !CityCatalog::RESERVED.include?(slug)
    end

    def database_name(slug)
      check!(slug)
      Rails.env.test? ? "rota_saude_test_city_#{slug}" : "rota_saude_city_#{slug}"
    end

    def role_name(slug)
      check!(slug)
      Rails.env.test? ? "rota_test_city_#{slug}" : "rota_city_#{slug}"
    end

    # URL que vai para cities.database_url: role e banco da cidade. Servidor e TLS
    # vêm de CITY_DATABASE_HOST (obrigatória em produção), CITY_DATABASE_PORT e
    # CITY_DATABASE_SSLMODE (default require em produção) — nunca da credencial do
    # provisioner, que o processo web não recebe. Fora de produção, cai em
    # DATABASE_HOST/DATABASE_PORT e sem sslmode.
    def url_for(slug:, password:)
      sslmode = ENV["CITY_DATABASE_SSLMODE"].presence || (Rails.env.production? ? "require" : nil)
      URI::Generic.build(scheme: "postgres", userinfo: "#{role_name(slug)}:#{password}",
                         host: city_database_host, port: city_database_port.to_i, path: "/#{database_name(slug)}",
                         query: sslmode && "sslmode=#{sslmode}").to_s
    end

    # Idempotente: cria o que falta e realinha a senha do role com a do catálogo
    # (um retry depois de uma falha no meio não deixa senha divergente).
    def ensure!(slug:, password:)
      role = role_name(slug)
      database = database_name(slug)

      with_provisioner do |conn|
        secret = conn.escape_literal(conn.encrypt_password(password, role, "scram-sha-256"))
        verb = role_exists?(conn, role) ? "ALTER" : "CREATE"
        conn.exec("#{verb} ROLE #{quote(role)} WITH LOGIN PASSWORD #{secret}")
        conn.exec("GRANT #{quote(role)} TO #{quote(conn.user)}")
        conn.exec("CREATE DATABASE #{quote(database)} OWNER #{quote(role)}") unless database_exists?(conn, database)
        conn.exec("REVOKE ALL ON DATABASE #{quote(database)} FROM PUBLIC")
      end
    end

    # Apaga banco e role (offboarding; limpeza de specs). Idempotente. FORCE derruba
    # as conexões ainda abertas no banco.
    #
    # DROP DATABASE ... WITH (FORCE) falha inteiro (PG::InsufficientPrivilege) se
    # QUALQUER sessão conectada não puder ser terminada por rota_provisioner —
    # inclusive um autovacuum worker: ele não pertence a role de login nenhum
    # (pg_stat_activity mostra usename nulo, backend_type "autovacuum worker"), e
    # pg_terminate_backend só deixa terminar quem tem privilégio do role DONO do
    # backend, ou superusuário/pg_signal_backend — nenhum dos dois é
    # rota_provisioner, de propósito (least-privilege, spec banco-por-cidade §4).
    # Um banco de cidade recém-criado/migrado é candidato natural a um ANALYZE
    # automático logo em seguida; a corrida foi reproduzida (achado do fix round
    # 1): o worker é transitório e libera a conexão sozinho em instantes, então
    # tentar de novo com um backoff curto resolve sem dar a rota_provisioner
    # nenhum privilégio além do que o plano já autoriza.
    DROP_ATTEMPTS = 5
    DROP_BACKOFF = 0.1 # segundos; dobra a cada tentativa (0.1, 0.2, 0.4, 0.8)

    def drop!(slug:)
      with_provisioner do |conn|
        drop_database!(conn, database_name(slug))
        conn.exec("DROP ROLE IF EXISTS #{quote(role_name(slug))}")
      end
    end

    def exists?(slug:)
      with_provisioner { |conn| database_exists?(conn, database_name(slug)) }
    end

    def provisioner_url
      ENV["PROVISIONER_DATABASE_URL"].presence || local_provisioner_url
    end

    private

    def check!(slug)
      raise InvalidSlug, "slug inválido para banco de cidade: #{slug.inspect}" unless valid_slug?(slug)
    end

    def city_database_host
      host = ENV["CITY_DATABASE_HOST"].presence
      return host if host
      raise ConfigMissing, "CITY_DATABASE_HOST ausente" if Rails.env.production?

      ENV.fetch("DATABASE_HOST", "127.0.0.1")
    end

    def city_database_port
      ENV["CITY_DATABASE_PORT"].presence || (Rails.env.production? ? "5432" : ENV.fetch("DATABASE_PORT", "5432"))
    end

    def local_provisioner_url
      raise ProvisionerMissing, "PROVISIONER_DATABASE_URL ausente" if Rails.env.production?

      host = ENV.fetch("DATABASE_HOST", "127.0.0.1")
      port = ENV.fetch("DATABASE_PORT", "5432")
      pwd  = ENV.fetch("ROTA_PROVISIONER_PASSWORD", "rota_provisioner")
      "postgres://rota_provisioner:#{pwd}@#{host}:#{port}/postgres"
    end

    def with_provisioner
      conn = PG.connect(provisioner_url)
      conn.set_notice_receiver { |_| }
      yield conn
    ensure
      conn&.close
    end

    def drop_database!(conn, database, attempt: 1)
      conn.exec("DROP DATABASE IF EXISTS #{quote(database)} WITH (FORCE)")
    rescue PG::InsufficientPrivilege
      raise if attempt >= DROP_ATTEMPTS

      sleep(DROP_BACKOFF * (2**(attempt - 1)))
      drop_database!(conn, database, attempt: attempt + 1)
    end

    def role_exists?(conn, role)
      conn.exec_params("SELECT 1 FROM pg_roles WHERE rolname = $1", [ role ]).ntuples == 1
    end

    def database_exists?(conn, database)
      conn.exec_params("SELECT 1 FROM pg_database WHERE datname = $1", [ database ]).ntuples == 1
    end

    def quote(identifier)
      PG::Connection.quote_ident(identifier)
    end
  end
end
