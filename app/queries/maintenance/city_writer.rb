# Entrada única da ESCRITA no banco de uma cidade, para a API de manutenção.
#
# Irmão de CityReader, com uma diferença de propósito: na leitura, qualquer
# falha vira erro de campo; na escrita, uma exceção de dentro do command é um
# RESULTADO — `error` na auditoria — e não pode ser confundida com "a cidade não
# respondeu". Só falha de conexão vira Unreachable. Uma conexão que cai NO MEIO
# do command também vira Unreachable: o command pode ou não ter comitado — é o
# "resultado desconhecido" da spec §9, e o correlation_id no evento de domínio
# da cidade é o que permite conferir.
#
# Só cidade `active` recebe escrita (CityLifecycle::SuspensionGuard).
module Maintenance
  class CityWriter
    class NotWritable < StandardError; end
    class Unreachable < StandardError; end

    def self.call(city)
      raise NotWritable, "cidade #{city.status}: só cidade ativa recebe escrita" unless city.servable?

      CityConnection.with(city) { yield }
    rescue *CityConnectionErrors::CLASSES => e
      redacted = CitySchema.redact(e.message)
      Rails.logger.warn("Maintenance::CityWriter: #{e.class}: #{redacted}")
      raise Unreachable, "#{e.class}: #{redacted}"
    end
  end
end
