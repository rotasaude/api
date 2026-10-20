# A suíte só roda no servidor Postgres de teste (postgres-test, via bin/test) —
# nunca no Postgres do host, que guarda os bancos de desenvolvimento. O servidor
# de teste se identifica por cluster_name; o before(:suite) do rails_helper
# confere antes do primeiro exemplo. Na CI (servidor descartável, sem como
# definir cluster_name no service container) o guard é desligado com
# TEST_SERVER_GUARD=off — e só esse valor o desliga.
module TestServerGuard
  EXPECTED = "rota_saude_test"

  class WrongServer < StandardError; end

  module_function

  def verify!(cluster_name, env = ENV)
    return if env["TEST_SERVER_GUARD"] == "off"
    return if cluster_name == EXPECTED

    raise WrongServer, "servidor de teste esperado: cluster_name=#{EXPECTED.inspect}, " \
                       "recebido: #{cluster_name.inspect} — a suíte só roda no postgres-test (bin/test)"
  end

  def check!
    verify!(PlatformRecord.connection.select_value("SHOW cluster_name"))
  end
end
