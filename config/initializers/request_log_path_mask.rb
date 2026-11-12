# O token de /v/<token> (conferência do documento clínico, ADR 0033) e o de
# /r/<token> (relatório do 19a) ficam no caminho, e a linha de requisição do
# Rails ("Started GET \"/v/<token>\" ...") os gravaria em claro no log de
# produção (nível info). Não é "só a página pública": o mesmo token abre
# /v/<token>/signed.pdf, o PDF assinado com o documento inteiro. O
# filter_parameters cobre o "Parameters:" mas não o caminho; aqui mudam só a
# mensagem de requisição e o caminho citado no RoutingError (DebugExceptions). /v/lookup não é token e
# segue legível.
#
# A detecção roda sobre uma cópia NORMALIZADA do caminho (percent-encoding
# decodificado e barras repetidas colapsadas), porque o roteador aceita
# "/v//TOKEN", "//v/TOKEN", "/%76/TOKEN" etc. como a mesma rota. Quando casa,
# o caminho inteiro é substituído pela forma normalizada e mascarada — assim a
# linha nunca guarda o token em forma alguma (crua nem percent-encoded). A
# query string não é decodificada e segue como veio. Caminho que não casa
# volta intacto.
#
# O mesmo vale para a URL curta dos arquivos (/exams/files/<token> e
# /tfd/files/<token>, o comprovante do TFD; FW6; e /ombudsman/files/<token>,
# o anexo da manifestação, módulo 33): o token abre o arquivo.
#
# A denúncia anônima (POST /citizen/ombudsman/anonymous_reports, módulo 33,
# Q58) não guarda o IP de quem denuncia: na linha de requisição dela o IP vira
# [FILTERED]. O IP segue valendo para o limite por IP (Rails.cache), que não
# passa pelo log.
#
# Os access logs do proxy reverso ficam fora do Rails: gate de go-live.
require "rails/rack/logger"

module RequestLogPathMask
  TOKEN_PATH = %r{\A/([vr])/(?!lookup(?:[/?]|\z))[^/?]+}i
  FILE_TOKEN_PATH = %r{\A/(exams|tfd|ombudsman)/files/[^/?]+}i

  ANONYMOUS_IP_PATH = %r{\A/citizen/ombudsman/anonymous_reports/?\z}i

  FALLBACK = "/[FILTERED]".freeze

  # Nunca levanta: opera em cópia binária (o caminho pode ter bytes inválidos ou
  # UTF-8 misto) e, se algo ainda falhar, devolve valor totalmente mascarado —
  # jamais o caminho original, que pode ser um caminho de token.
  def self.mask(path)
    path = path.to_s
    info, query = path.b.split("?", 2)
    normalized = normalize(info)
    if normalized.match?(TOKEN_PATH)
      masked = normalized.sub(TOKEN_PATH, '/\1/[FILTERED]')
    elsif normalized.match?(FILE_TOKEN_PATH)
      masked = normalized.sub(FILE_TOKEN_PATH, '/\1/files/[FILTERED]')
    else
      return path
    end
    masked = "#{masked}?#{query}" if query
    masked.force_encoding(Encoding::UTF_8).scrub("?")
  rescue StandardError
    FALLBACK
  end

  # O caminho (sem a query, normalizado) cuja linha de requisição não guarda o IP.
  def self.hide_ip?(path) = normalize(path.to_s.b.split("?", 2).first).match?(ANONYMOUS_IP_PATH)

  # Decodifica %XX (sem tratar "+" como espaço) e colapsa barras repetidas,
  # em binário.
  def self.normalize(info)
    info.to_s.b.gsub(/%([0-9a-fA-F]{2})/n) { $1.hex.chr }.squeeze("/")
  end

  # Mascara os caminhos entre aspas de um texto de log (ex.: a mensagem do
  # RoutingError, `No route matches [GET] "/%76/TOKEN"`); o resto não muda.
  def self.mask_quoted_paths(text)
    text.to_s.gsub(/"(\/[^"]*)"/) { %("#{mask($1)}") }
  rescue StandardError
    text.to_s.gsub(/"\/[^"]*"/, %("#{FALLBACK}"))
  end

  module Started
    private

    def started_request_message(request)
      path = request.filtered_path
      masked = RequestLogPathMask.mask(path)
      message = super
      message = message.sub(%("#{path}"), %("#{masked}")) unless masked == path
      return message unless RequestLogPathMask.hide_ip?(path)

      ip = request.remote_ip.to_s
      message = message.sub(" for #{ip} at ", " for [FILTERED] at ")
      # Formato inesperado: nunca o IP; cai no fallback abaixo.
      raise "IP left in the request line" if ip.present? && message.include?(ip)

      message
    rescue StandardError
      %(Started #{request.request_method} "#{FALLBACK}")
    end
  end

  # O RoutingError de caminho sem rota (ex.: /%76/TOKEN, que o roteador não
  # decodifica) cita o caminho cru na mensagem que o DebugExceptions loga.
  module Exceptions
    private

    def compose_exception_message(wrapper)
      super.map { |line| line.is_a?(String) ? RequestLogPathMask.mask_quoted_paths(line) : line }
    end
  end
end

Rails::Rack::Logger.prepend(RequestLogPathMask::Started)
ActionDispatch::DebugExceptions.prepend(RequestLogPathMask::Exceptions)
