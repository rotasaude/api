# Prova de espera real em specs com threads reais (sem fixture transacional):
# a conexão do exemplo (aberta pelo around de city_test_databases.rb) já está
# na cidade de teste e não é dona da disputa, então basta consultar
# pg_stat_activity nela para saber se alguma sessão está parada num lock.
module LockWait
  def wait_for_lock_wait(timeout: 5)
    deadline = Time.current + timeout
    loop do
      count = ApplicationRecord.connection.select_value(
        "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock'"
      ).to_i
      return true if count.positive?
      return false if Time.current > deadline

      sleep 0.05
    end
  end
end

RSpec.configure { |c| c.include LockWait }
