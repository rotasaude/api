# Base do domínio de uma cidade. A conexão real é resolvida em runtime por
# CityConnection, um shard por cidade.
#
# O `connects_to` abaixo é OBRIGATÓRIO e roda uma única vez, no boot: sem ele
# CityRecord não é uma "connection class", e connected_to levanta
# NotImplementedError ("only allowed on the abstract class that established the
# connection"). O shard :bootstrap nunca é usado para servir cidade — ele só
# existe para registrar CityRecord no connection handler.
#
# NUNCA chame connects_to de novo: ele reconstrói o mapa inteiro de shards e
# derruba cidades em voo (spike 1: 171.620 interrupções sob tráfego).
#
# Enquanto o Plano 2 não reparenta o domínio, só os specs de isolamento
# herdam daqui.
class CityRecord < ActiveRecord::Base
  self.abstract_class = true

  connects_to shards: { bootstrap: { writing: :primary } }
end
