# app/services/medications/catmat/client.rb
# Cliente da API aberta do Compras.gov para o CATMAT classe 6505 (ADR 0033;
# spec §3; conferida em 2026-10-09, Desvio 1). Lê todas as páginas (pagina a
# partir de 1, até totalPaginas) e confere o total: o catálogo nunca é
# importado pela metade. Passageiro (rede, timeout, 5xx, JSON inválido) tenta
# de novo 2 vezes com espera; o corpo da resposta nunca vai a mensagem ou log.
require "net/http"

module Medications
  module Catmat
    class Client
      class Unavailable < StandardError; end
      class Incomplete < StandardError; end

      BASE_URL = "https://dadosabertos.compras.gov.br".freeze
      PATH = "/modulo-material/4_consultarItemMaterial".freeze
      CLASS_CODE = 6505
      PAGE_SIZE = 500
      MAX_PAGES = 100
      RETRIES = 2
      BACKOFF = [ 2, 10 ].freeze

      def initialize(base_url: ENV.fetch("CATMAT_API_URL", BASE_URL), page_size: PAGE_SIZE, sleeper: ->(seconds) { sleep(seconds) })
        @base_url = base_url.chomp("/")
        @page_size = page_size
        @sleeper = sleeper
      end

      # Uma linha da API (hash com as chaves do envelope) -> Row. Único ponto de
      # mapeamento: o FixtureClient reaproveita (e é o que carrega este arquivo).
      def self.build_row(row)
        Row.new(catmat_code: Integer(row.fetch("codigoItem")), pdm_code: row["codigoPdm"]&.then { |code| Integer(code) },
                pdm_name: row["nomePdm"].to_s, description: row.fetch("descricaoItem").to_s,
                updated_at: row["dataHoraAtualizacao"].presence&.then { |value| Time.find_zone("UTC").parse(value) })
      end

      def fetch_all
        rows = []
        total = nil
        page = 1
        loop do
          body = get_page(page)
          page_total = Integer(body.fetch("totalRegistros"))
          pages = Integer(body.fetch("totalPaginas"))
          total ||= page_total
          raise Incomplete, "totalRegistros mudou entre páginas" if page_total != total

          batch = Array(body.fetch("resultado"))
          raise Incomplete, "página #{page} vazia antes da última (#{pages})" if batch.empty? && page <= pages && total.positive?

          rows.concat(batch)
          break if page >= pages

          page += 1
          raise Incomplete, "mais de #{MAX_PAGES} páginas" if page > MAX_PAGES
        end
        read = rows.map { |row| self.class.build_row(row) }.uniq(&:catmat_code)
        raise Incomplete, "lidos #{read.size}, total #{total}" if read.size != total

        # A consulta já pede statusItem=true; item inativo que vier mesmo assim não entra.
        inactive = rows.select { |row| row["statusItem"] == false }.to_set { |row| Integer(row["codigoItem"]) }
        read.reject { |row| inactive.include?(row.catmat_code) }
      rescue KeyError, ArgumentError, TypeError
        raise Unavailable, "resposta fora do formato esperado"
      end

      private

      def get_page(page)
        attempts = 0
        begin
          attempts += 1
          response = http_get(page)
          raise Unavailable, "HTTP #{response.code} na página #{page}" unless response.code == "200"

          body = JSON.parse(response.body)
          raise Unavailable, "resposta fora do formato esperado na página #{page}" unless body.is_a?(Hash)

          body
        rescue Unavailable, JSON::ParserError, Net::OpenTimeout, Net::ReadTimeout, SocketError, SystemCallError, OpenSSL::SSL::SSLError,
               EOFError, IOError, Net::ProtocolError, Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError, Timeout::Error => e
          if attempts <= RETRIES && !client_error?(e)
            @sleeper.call(BACKOFF.fetch(attempts - 1, BACKOFF.last))
            retry
          end
          raise Unavailable, "CATMAT indisponível na página #{page} (#{e.class.name.demodulize})"
        end
      end

      def client_error?(error) = error.is_a?(Unavailable) && error.message.match?(/HTTP 4\d\d/)

      def http_get(page)
        uri = URI("#{@base_url}#{PATH}")
        uri.query = URI.encode_www_form(pagina: page, tamanhoPagina: @page_size, codigoClasse: CLASS_CODE, statusItem: true)
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 10, read_timeout: 60) do |http|
          http.request(Net::HTTP::Get.new(uri, "Accept" => "application/json"))
        end
      end
    end
  end
end
