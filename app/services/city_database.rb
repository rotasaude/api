# Banco e role de uma cidade no Postgres (spec banco-por-cidade §4, Plano 4).
#
# Tudo aqui conecta como rota_provisioner — CREATEDB e CREATEROLE, sem
# superusuário — por PROVISIONER_DATABASE_URL. Em produção só o worker recebe essa
# URL: o processo web não cria nem apaga banco.
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

    # URL que vai para cities.database_url: role e banco da cidade, no mesmo
    # servidor do provisioner.
    def url_for(slug:, password:)
      server = URI.parse(provisioner_url)
      URI::Generic.build(scheme: "postgres", userinfo: "#{role_name(slug)}:#{password}",
                         host: server.host, port: server.port, path: "/#{database_name(slug)}").to_s
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
    def drop!(slug:)
      with_provisioner do |conn|
        conn.exec("DROP DATABASE IF EXISTS #{quote(database_name(slug))} WITH (FORCE)")
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
