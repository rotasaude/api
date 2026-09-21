# Entrada única da ESCRITA no banco de uma cidade, para a API de manutenção.
#
# Irmão de CityReader, com uma diferença de propósito: na leitura, qualquer
# falha vira erro de campo; na escrita, uma exceção de dentro do command é um
# RESULTADO — `error` na auditoria — e não pode ser confundida com "a cidade não
# respondeu". Só falha de conexão vira Unreachable, e ela diz SE o bloco já
# tinha começado (spec §9):
#   - antes do bloco (a conexão nem abriu): nada
#     rodou na cidade — `error` é a verdade;
#   - depois do bloco começar (caiu no meio do command ou no COMMIT): o command
#     pode ou não ter comitado — é o "resultado desconhecido", e o
#     correlation_id no evento de domínio da cidade é o que permite conferir.
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

    def self.ensure_writable!(city)
      raise NotWritable, "cidade #{city.status}: só cidade ativa recebe escrita" unless city.servable?
    end

    def self.call(city)
      ensure_writable!(city)

      started = false
      CityConnection.with(city) do
        started = true
        yield
      end
    rescue *CityConnectionErrors::CLASSES => e
      redacted = CitySchema.redact(e.message)
      Rails.logger.warn("Maintenance::CityWriter: #{e.class}: #{redacted} (bloco iniciado: #{started})")
      raise Unreachable.new("#{e.class}: #{redacted}", started: started)
    end
  end
end
