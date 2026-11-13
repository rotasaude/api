# Preparo caro uma vez por arquivo (api#159). Os specs de semente refaziam a
# cadeia inteira do db/seeds.rb no `before` de cada exemplo, e o custo crescia
# com cada módulo novo.
#
# `seed_once { ... }` roda o bloco uma vez, antes do primeiro exemplo do grupo,
# dentro de CityConnection.with(TEST_CITY_A), como o harness faz com cada
# exemplo. Nada é commitado: antes do bloco, cada pool de escrita é pinado numa
# transação (o mesmo pin_connection! do Rails). A transação de fixture de cada
# exemplo vira um savepoint dentro dela e volta ao fim do exemplo, então todo
# exemplo parte do mesmo estado semeado. O after(:context) desfaz a transação
# externa, e o banco volta a ficar como estava antes do arquivo.
#
# O bloco não pode abrir pool novo: o que ele escrevesse ali seria commitado
# (e ficaria no banco). Se abrir, o preparo falha com NewPoolOpened e o arquivo
# inteiro falha, em vez de seguir com estado vazado.
#
# Instância de `let` não existe no before(:context): o bloco chama os helpers
# direto. Variável de instância criada no bloco chega aos exemplos (cópia rasa,
# a do RSpec).
module SeedOnce
  class NewPoolOpened < StandardError; end

  def self.writing_pools = ActiveRecord::Base.connection_handler.connection_pool_list(:writing)

  def self.pin!(pools)
    pinned = []
    pools.each do |pool|
      pool.pin_connection!(true)
      pinned << pool
    end
    pinned
  rescue StandardError
    unpin!(pinned)
    raise
  end

  def self.unpin!(pools)
    pools.reverse_each { |pool| pool.unpin_connection! }
  end

  def self.refuse_new_pools!(pinned)
    opened = writing_pools - pinned
    return if opened.empty?

    names = opened.map { |pool| "#{pool.connection_descriptor.name}/#{pool.shard}" }
    raise NewPoolOpened, "seed_once opened pools outside the pinned transaction: #{names.join(', ')}"
  end

  def self.reset_process_state!
    Current.reset
    CityCatalog.reset_cache!
    Rails.cache.clear
  end

  def seed_once(&block)
    before(:context) do
      CityConnection.with(TEST_CITY_A) do
        pools = SeedOnce.pin!(SeedOnce.writing_pools)
        @__seed_once_pools = pools
        begin
          Current.city = TEST_CITY_A
          instance_exec(&block)
          SeedOnce.refuse_new_pools!(pools)
        rescue Exception # rubocop:disable Lint/RescueException -- re-raised unchanged
          SeedOnce.unpin!(pools)
          @__seed_once_pools = nil
          raise
        end
      end
    ensure
      SeedOnce.reset_process_state!
    end

    after(:context) do
      SeedOnce.unpin!(@__seed_once_pools) if @__seed_once_pools
    ensure
      SeedOnce.reset_process_state!
    end
  end
end

RSpec.configure { |config| config.extend SeedOnce }
