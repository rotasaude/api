# Schema dos bancos de CIDADE: onde moram as migrations, qual versão este código
# espera e como aplicar (spec banco-por-cidade §4, Plano 4).
#
# As migrations de cidade ficam em db/city_migrate, fora de toda config de
# config/database.yml: nenhum db:migrate genérico as alcança.
#
# ATENÇÃO — migrate!, current_version e backfill_versions! usam
# DatabaseTasks.with_temporary_connection, que troca a conexão de
# ActiveRecord::Base durante o bloco (o Rails 8.1 migra sempre por ela). O Solid
# Queue usa essa mesma conexão. Só chame em processo de uma thread (rake,
# subprocesso) — nunca dentro de job ou request. O provisionamento migra por
# subprocesso (CityMigrations::Subprocess).
module CitySchema
  MIGRATIONS_PATH = "db/city_migrate"

  class << self
    def migrations_paths
      [ Rails.root.join(MIGRATIONS_PATH).to_s ]
    end

    # Maior versão presente em db/city_migrate: o schema que ESTE código espera.
    def expected_version
      @expected_version ||= Dir[File.join(migrations_paths.first, "*.rb")].map { |f| File.basename(f).to_i }.max.to_i
    end

    # Config ad-hoc de um banco de cidade com as migrations de cidade. Nunca é
    # registrada em database.yml.
    def db_config_for(url)
      resolved = ActiveRecord::Base.configurations.resolve(url.to_s)
      ActiveRecord::DatabaseConfigurations::HashConfig.new(
        Rails.env, "city", resolved.configuration_hash.merge(migrations_paths: migrations_paths)
      )
    end

    # Aplica as migrations pendentes e devolve a versão resultante. O Migrator do
    # Rails pega um advisory lock por banco: duas execuções na mesma cidade não
    # correm juntas (a segunda levanta ActiveRecord::ConcurrentMigrationError).
    def migrate!(url)
      with_city_connection(url) do |conn|
        conn.pool.migration_context.migrate
        conn.pool.migration_context.current_version
      end
    end

    def current_version(url)
      with_city_connection(url) { |conn| conn.pool.migration_context.current_version }
    end

    # Completa schema_migrations ABAIXO da maior versão já registrada, sem nunca
    # declarar aplicada uma versão maior. Conserta bancos carregados pelo dump
    # antes de load_schema conhecer db/city_migrate — só a versão do dump ficava
    # registrada, e city:migrate tentaria recriar o schema inteiro.
    def backfill_versions!(url)
      with_city_connection(url) do |conn|
        version = conn.pool.migration_context.current_version
        conn.assume_migrated_upto_version(version) if version.positive?
        conn.pool.migration_context.current_version
      end
    end

    # Tira usuário e senha de toda URL de banco num texto (mensagem de erro, saída
    # de subprocesso) antes de ir para log ou exceção.
    def redact(text)
      text.to_s.gsub(%r{://[^/\s@]+@}, "://***@")
    end

    private

    def with_city_connection(url, &block)
      verbose_was = ActiveRecord::Migration.verbose
      ActiveRecord::Migration.verbose = false
      ActiveRecord::Tasks::DatabaseTasks.with_temporary_connection(db_config_for(url), &block)
    ensure
      ActiveRecord::Migration.verbose = verbose_was
    end
  end
end
