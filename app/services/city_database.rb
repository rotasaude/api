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
  # PG::Error (não StandardError) de propósito: CityLifecycle::Offboard já
  # resgata qualquer PG::Error do drop e devolve :drop_failed com a mensagem
  # redigida (CitySchema.redact) — reaproveita esse caminho em vez de um tipo
  # novo que passaria batido pelo rescue existente.
  class DropBlocked < PG::Error; end

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

    # Apaga banco e role (offboarding; limpeza de specs). Idempotente, sem FORCE
    # e sem retry — determinístico (fix round 2 do hardening pré-Plano 6).
    #
    # FORCE falhava inteiro (PG::InsufficientPrivilege) se QUALQUER sessão
    # conectada não pudesse ser terminada por rota_provisioner — inclusive um
    # autovacuum worker, que não pertence a role de login nenhum (pg_stat_activity
    # mostra usename nulo, backend_type "autovacuum worker"); só um backoff com
    # retry escondia essa corrida transitória. A sequência abaixo evita o
    # problema em vez de tentar de novo:
    #
    #   1. ALTER DATABASE ... ALLOW_CONNECTIONS false — fecha a porta pra sessão
    #      nova durante os passos seguintes. Exige ser dono do banco (ou membro do
    #      role dono); rota_provisioner é membro via o GRANT de ensure!.
    #   2. pg_terminate_backend nas sessões "client backend" do banco (exclui
    #      autovacuum worker e outros processos internos de propósito: terminar o
    #      backend de outro role exige ser membro dele ou pg_signal_backend, e
    #      rota_provisioner só é membro do role da própria cidade — sessão de
    #      cliente da cidade É NORMALMENTE esse role, mas não SEMPRE: uma sessão
    #      de superusuário/DBA conectada ao banco da cidade também é "client
    #      backend" e rota_provisioner não pode terminá-la — vira DropBlocked
    #      no passo 3, não um erro silencioso).
    #   3. DROP DATABASE IF EXISTS, sem FORCE — o próprio Postgres sinaliza
    #      autovacuum e outros processos internos e espera uns segundos
    #      (CountOtherDBBackends) antes de decidir que o banco ainda está em uso;
    #      não precisamos mais fazer isso na mão. Se uma sessão cliente reaparecer
    #      nessa janela, o passo 1 já impede.
    #
    # Nenhum passo dá a rota_provisioner privilégio além do que o plano já
    # autoriza (least-privilege, spec banco-por-cidade §4).
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

    def drop_database!(conn, database)
      return unless database_exists?(conn, database)

      begin
        conn.exec("ALTER DATABASE #{quote(database)} WITH ALLOW_CONNECTIONS false")
      rescue PG::InvalidCatalogName
        return # apagado entre o check acima e o ALTER: já não há nada a fazer
      end

      terminate_client_backends!(conn, database)

      begin
        conn.exec("DROP DATABASE IF EXISTS #{quote(database)}")
      rescue PG::ObjectInUse => e
        raise DropBlocked, "banco #{database} ainda em uso após terminar as sessões: #{e.message}"
      end
    end

    # Só sessões "client backend" (normalmente as da própria cidade, via role
    # da cidade — mas uma sessão de superusuário/DBA também conta como
    # "client backend" e não é derrubável por rota_provisioner, ver comentário
    # de drop! acima): autovacuum worker e outros processos internos ficam de
    # fora de propósito e são resolvidos pelo próprio DROP DATABASE.
    #
    # Filtro por usename IS NOT NULL, não por backend_type = 'client backend'
    # (achado ao escrever o teste do caminho DropBlocked, I1 do review):
    # pg_stat_activity NULA backend_type (e outras colunas) para uma sessão de
    # role que rota_provisioner não enxerga plenamente (sem SUPERUSER nem
    # pg_read_all_stats) — mesmo quando essa sessão É uma "client backend" de
    # verdade. Com o filtro antigo, essa sessão simplesmente desaparecia do
    # SELECT (nenhuma linha, nenhum erro), pg_terminate_backend nunca era
    # sequer chamado nela, e o DROP DATABASE seguinte falhava com
    # PG::ObjectInUse — uma mensagem que embute o texto cru do Postgres, não o
    # "N sessão(ões)" só-contagem que DropBlocked promete. usename SEMPRE
    # aparece (não é uma coluna restrita), e só processos internos
    # (autovacuum, checkpointer, bgwriter, walwriter, ...) têm usename nulo —
    # então o filtro continua excluindo exatamente os mesmos processos
    # internos de antes, e passa a incluir sessões de role alheia também.
    def terminate_client_backends!(conn, database)
      conn.exec_params(<<~SQL, [ database ])
        SELECT pg_terminate_backend(pid)
        FROM pg_stat_activity
        WHERE datname = $1 AND pid <> pg_backend_pid() AND usename IS NOT NULL
      SQL
    rescue PG::InsufficientPrivilege
      blocking = conn.exec_params(<<~SQL, [ database ]).getvalue(0, 0)
        SELECT count(*)
        FROM pg_stat_activity
        WHERE datname = $1 AND pid <> pg_backend_pid() AND usename IS NOT NULL
      SQL
      raise DropBlocked, "#{blocking} sessão(ões) bloqueando o drop de #{database}"
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
