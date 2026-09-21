# Entrada única da ESCRITA no banco de uma cidade, para a API de manutenção.
#
# Irmão de CityReader, com uma diferença de propósito: na leitura, qualquer
# falha vira erro de campo; na escrita, uma exceção de dentro do command é um
# RESULTADO — `error` na auditoria — e não pode ser confundida com "a cidade não
# respondeu". Só falha de conexão vira Unreachable, e ela diz SE o bloco já
# tinha começado (spec §9):
#   - antes do bloco (a conexão nem abriu, ou caiu no BEGIN/SET LOCAL): nada
#     rodou na cidade — `error` é a verdade;
#   - depois do bloco começar (caiu no meio do command ou no COMMIT): o command
#     pode ou não ter comitado — é o "resultado desconhecido", e o
#     correlation_id no evento de domínio da cidade é o que permite conferir.
#
# Tetos de espera (só na ESCRITA — leitura e workers não passam por aqui): o
# bloco roda numa transação que começa com SET LOCAL lock_timeout e
# statement_timeout. Os commands travam a linha do protocolo (`lock!`); sem
# teto, uma trava presa por outra sessão prende a thread do Puma até o
# cliente desistir. A espera estourada levanta (LockWaitTimeout /
# QueryCanceled) e vira `error` + CITY_WRITE_FAILED como qualquer outra
# exceção do command. SET LOCAL morre com a transação, então nada vaza para a
# próxima requisição que pegar a mesma conexão do pool.
#
# A transação é `joinable: false`: o `ApplicationRecord.transaction` de cada
# command vira SAVEPOINT dentro dela (sem isso, ele se juntaria a esta, e um
# `raise ActiveRecord::Rollback` do command seria engolido pelo bloco de
# dentro sem desfazer nada). `lock!` + reconferência continuam valendo: a
# trava dura até o COMMIT desta transação.
#
# Só cidade `active` recebe escrita (CityLifecycle::SuspensionGuard).
module Maintenance
  class CityWriter
    class NotWritable < StandardError; end

    class Unreachable < StandardError
      def initialize(message = nil, started: false)
        super(message)
        @started = started
      end

      # true: a conexão caiu depois que o bloco (o command) começou — resultado
      # desconhecido; false: nada rodou na cidade.
      def started? = @started
    end

    LOCK_TIMEOUT = "5s"
    STATEMENT_TIMEOUT = "10s"

    def self.ensure_writable!(city)
      raise NotWritable, "cidade #{city.status}: só cidade ativa recebe escrita" unless city.servable?
    end

    def self.call(city)
      ensure_writable!(city)

      started = false
      CityConnection.with(city) do
        CityRecord.transaction(joinable: false) do
          connection = CityRecord.lease_connection
          connection.execute("SET LOCAL lock_timeout = #{connection.quote(LOCK_TIMEOUT)}")
          connection.execute("SET LOCAL statement_timeout = #{connection.quote(STATEMENT_TIMEOUT)}")
          started = true
          yield
        end
      end
    rescue *CityConnectionErrors::CLASSES => e
      redacted = CitySchema.redact(e.message)
      Rails.logger.warn("Maintenance::CityWriter: #{e.class}: #{redacted} (bloco iniciado: #{started})")
      raise Unreachable.new("#{e.class}: #{redacted}", started: started)
    end
  end
end
