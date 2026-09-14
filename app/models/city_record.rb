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
#
# O shard :bootstrap aponta para `city_unset` (rota_saude_no_city_selected),
# um banco sem NENHUMA tabela — ver config/database.yml e
# lib/tasks/city.rake. Isso é deliberado: sem cidade selecionada, qualquer
# query de domínio levanta ActiveRecord::StatementInvalid (PG::UndefinedTable)
# em vez de ler o banco compartilhado em silêncio. Um banco de fato
# inexistente também fecharia essa porta, mas derrubava a suíte inteira: o
# setup_transactional_fixtures do RSpec pina todo pool registrado — inclusive
# este — antes de cada exemplo, e não é preguiçoso como o boot do Rails é.
# Antes desta mudança, :bootstrap apontava para :primary e falhava ABERTO.
class CityRecord < ActiveRecord::Base
  self.abstract_class = true

  connects_to shards: { bootstrap: { writing: :city_unset } }
end
