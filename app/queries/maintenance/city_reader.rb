# Entrada única no banco de uma cidade, para a API de manutenção (spec §8).
#
# Três saídas:
#
#   1. Archived: status sem banco para conectar — nem tenta.
#   2. Unreachable: falha de CONEXÃO (Maintenance::CityConnectionErrors::CLASSES).
#      A mensagem passa por CitySchema.redact e é publicada — PG::ConnectionBad
#      traz a URL de conexão inteira, com a senha do role da cidade; sem a
#      redação, o caminho de erro — o menos exercitado — publicaria o segredo
#      que todo o resto esconde.
#   3. Failed: qualquer OUTRA exceção. A mensagem original é texto sem
#      controle — um bug de código pode interpolar dado de cidadão — então só
#      o nome da classe sai, na resposta e no log (resíduo do Plano 4, achado
#      na revisão final: a versão anterior tratava qualquer exceção como
#      Unreachable e publicava a mensagem crua de um bug de código).
#
# Em nenhum caso a operação inteira derruba: cidade inalcançável ou falha de
# leitura viram erro NAQUELE campo — as cidades que respondem respondem.
module Maintenance
  class CityReader
    # Status sem banco para conectar: tentar é garantia de erro, e erro previsto
    # não é diagnóstico (mesma lista de CityInventory::SKIPPED_STATUSES).
    ARCHIVED_STATUSES = %w[archived].freeze

    class Archived < StandardError; end
    class Unreachable < StandardError; end
    class Failed < StandardError; end

    def self.call(city)
      raise Archived, "cidade #{city.status}: sem banco para conectar" if ARCHIVED_STATUSES.include?(city.status)

      CityConnection.with(city) { yield }
    rescue Archived
      raise
    rescue *CityConnectionErrors::CLASSES => e
      redacted = CitySchema.redact(e.message)
      # T3 (achado na revisão final do Plano 4): sem isto, um bug de CÓDIGO
      # (não uma cidade de fato inalcançável) vira CITY_UNREACHABLE em
      # silêncio — ninguém vê a classe da exceção fora da resposta GraphQL
      # (que também é redigida, mas não é onde se procura um bug). A MENSAGEM
      # nunca vai pro log crua — só a versão que já passou por
      # CitySchema.redact.
      Rails.logger.warn("Maintenance::CityReader: #{e.class}: #{redacted}")
      raise Unreachable, "#{e.class}: #{redacted}"
    rescue StandardError => e
      # Qualquer exceção que NÃO é de conexão: a mensagem pode carregar dado
      # de cidadão (um bug de interpolação, por exemplo) e nunca é publicada
      # nem logada — só o nome da classe.
      Rails.logger.warn("Maintenance::CityReader: #{e.class} (mensagem omitida)")
      raise Failed, e.class.name
    end
  end
end
