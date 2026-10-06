# Sufixo opcional dos bancos de cidade de TESTE (ROTA_TEST_DB_SUFFIX), para duas
# sessões rodarem a suíte no mesmo Postgres sem dividir rota_saude_test_city_a/_b
# nem os bancos de cidades provisionadas pelos specs. Sem a variável (ou vazia),
# os nomes são exatamente os de sempre.
#
# Ruby puro, sem Rails: usado por lib/tasks/city.rake (city:test_databases),
# app/services/city_database.rb (só em test) e spec/support/city_test_databases.rb.
# Um valor fora de [a-z0-9_] levanta — o nome vai cru para CREATE DATABASE.
module TestDatabaseSuffix
  VARIABLE = "ROTA_TEST_DB_SUFFIX"
  PATTERN = /\A[a-z0-9_]*\z/

  class Invalid < ArgumentError; end

  module_function

  def value(env = ENV)
    raw = env.fetch(VARIABLE, "")
    return raw if raw.match?(PATTERN)

    raise Invalid, "#{VARIABLE}=#{raw.inspect} inválido: use só [a-z0-9_] (ex.: _mod17), ou deixe vazio"
  end

  def apply(name, env = ENV)
    "#{name}#{value(env)}"
  end
end
