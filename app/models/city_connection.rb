# Registry de pools, um por cidade.
#
# INVARIANTE (spike 1, 2026-09-12): `connects_to` reconstrói o mapa inteiro de
# shards e derruba cidades já ativas — 171.620 interrupções sob tráfego. Só
# `establish_connection` adiciona um pool isolado (0,11 ms, zero interrupções).
# NUNCA chame connects_to em CityRecord.
#
# O registro é preguiçoso POR PROCESSO: com Puma multi-worker e réplicas,
# provisionar não avisa ninguém — cada processo descobre a cidade ao servi-la.
class CityConnection
  class InvalidCityDatabase < StandardError; end

  MUTEX = Mutex.new

  class << self
    # Domínio E fila da cidade (Plano 5): um job enfileirado aqui dentro cai na fila
    # do banco da cidade, não na de plataforma.
    def with(city, &block)
      ensure_pool(city)
      ActiveRecord::Base.connected_to_many([ CityRecord, SolidQueue::Record ], role: :writing, shard: city.shard, &block)
    end

    # Verificado em 2026-09-12 contra o Rails 8.1.3, os pontos em que registrar
    # uma cidade pode falhar:
    #   URL malformada        -> DatabaseConfigurations::InvalidConfigurationError
    #                            (build_db_config_from_string, URI.parse)
    #   URL sem database      -> UrlConfig com database nulo (guard abaixo)
    #   scheme de adapter que não existe (ex.: "postgress://")
    #                         -> AdapterNotFound / AdapterNotSpecified, levantado
    #                            por establish_connection em si (validate!),
    #                            não por database_config — por isso o rescue cobre
    #                            o método inteiro, não só a resolução da config.
    #   password com caractere que quebra URI.parse (ex.: "[", espaço)
    #                         -> URI::InvalidURIError
    # Todos viram InvalidCityDatabase, para o chamador ter um erro só. A
    # mensagem NUNCA interpola e.message: a exception original do Rails
    # embute a database_url inteira (com credenciais) no texto — deixar isso
    # vazar para logs/error tracker anularia o encrypts :database_url do City.
    def ensure_pool(city)
      return if registered?(city.shard)

      MUTEX.synchronize do
        next if registered?(city.shard)

        config = database_config(city)
        # A fila da cidade mora no banco dela (Plano 5). O pool de fila é registrado
        # antes do de domínio: registered? olha o de domínio, então um existe só se
        # o outro já existe.
        ActiveRecord::Base.connection_handler.establish_connection(
          config, owner_name: SolidQueue::Record, role: :writing, shard: city.shard
        )
        ActiveRecord::Base.connection_handler.establish_connection(
          config, owner_name: CityRecord, role: :writing, shard: city.shard
        )
      end
    rescue ActiveRecord::DatabaseConfigurations::InvalidConfigurationError,
           ActiveRecord::AdapterNotFound,
           ActiveRecord::AdapterNotSpecified,
           URI::InvalidURIError
      raise InvalidCityDatabase, "cidade #{city.slug}: database_url inválida"
    end

    def registered?(shard)
      !ActiveRecord::Base.connection_handler
        .retrieve_connection_pool(CityRecord.name, role: :writing, shard: shard)
        .nil?
    end

    # Rotação, suspensão e desligamento de cidade precisam derrubar o pool.
    # No-op se a cidade nunca foi registrada neste processo.
    def forget(shard)
      handler = ActiveRecord::Base.connection_handler
      handler.remove_connection_pool(CityRecord.name, role: :writing, shard: shard)
      handler.remove_connection_pool(SolidQueue::Record.name, role: :writing, shard: shard)
    end

    # Config resolvida do banco da cidade. Pública para o worker da cidade
    # (CityWorkers::Child), que liga o Solid Queue do processo inteiro a ela.
    def database_config(city)
      url = city.database_url.to_s
      url += (url.include?("?") ? "&" : "?") + "pool=#{pool_size}"

      resolved = ActiveRecord::Base.configurations.resolve(url)
      if resolved.database.blank?
        raise InvalidCityDatabase, "cidade #{city.slug}: database_url sem database"
      end

      resolved
    end

    private

    def pool_size
      ENV.fetch("RAILS_MAX_THREADS", 5).to_i
    end
  end
end
