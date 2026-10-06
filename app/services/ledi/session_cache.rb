# Cookie JSESSIONID do PEC por cidade, em memória do processo (spec §6.4). A
# chave inclui o set_at da credencial: credencial trocada nunca reaproveita o
# cookie da antiga. Nunca persiste, nunca loga.
module Ledi
  module SessionCache
    module_function

    def store = @store ||= Concurrent::Map.new

    def fetch(key, &block) = store.compute_if_absent(key, &block)

    def forget(key) = store.delete(key)

    def clear! = store.clear
  end
end
