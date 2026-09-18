# Entrada única no banco de uma cidade, para a API de manutenção (spec §8).
#
# Duas regras que este arquivo existe para sustentar:
#
#   1. Cidade inalcançável NÃO derruba a operação. É justamente quando algo
#      quebrou que a ferramenta precisa responder — as cidades que respondem
#      respondem, e a que falhou vira erro NAQUELE campo.
#   2. A mensagem passa por CitySchema.redact. PG::ConnectionBad traz a URL de
#      conexão inteira, com a senha do role da cidade; sem isto, o caminho de
#      erro — o menos exercitado — publicaria o segredo que todo o resto esconde.
module Maintenance
  class CityReader
    # Status sem banco para conectar: tentar é garantia de erro, e erro previsto
    # não é diagnóstico (mesma lista de CityInventory::SKIPPED_STATUSES).
    ARCHIVED_STATUSES = %w[archived].freeze

    class Archived < StandardError; end
    class Unreachable < StandardError; end

    def self.call(city)
      raise Archived, "cidade #{city.status}: sem banco para conectar" if ARCHIVED_STATUSES.include?(city.status)

      CityConnection.with(city) { yield }
    rescue Archived
      raise
    rescue StandardError => e
      redacted = CitySchema.redact(e.message)
      # T3 (achado na revisão final do Plano 4): sem isto, um bug de CÓDIGO
      # (não uma cidade de fato inalcançável) vira CITY_UNREACHABLE em
      # silêncio — ninguém vê a classe da exceção fora da resposta GraphQL
      # (que também é redigida, mas não é onde se procura um bug). A MENSAGEM
      # nunca vai pro log crua — só a versão que já passou por
      # CitySchema.redact.
      Rails.logger.warn("Maintenance::CityReader: #{e.class}: #{redacted}")
      raise Unreachable, "#{e.class}: #{redacted}"
    end
  end
end
