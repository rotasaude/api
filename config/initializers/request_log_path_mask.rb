# O token de /v/<token> (conferência do documento clínico, ADR 0033) e o de
# /r/<token> (relatório do 19a) ficam no caminho, e a linha de requisição do
# Rails ("Started GET \"/v/<token>\" ...") os gravaria em claro no log de
# produção (nível info). Não é "só a página pública": o mesmo token abre
# /v/<token>/signed.pdf, o PDF assinado com o documento inteiro. O
# filter_parameters cobre o "Parameters:" mas não o caminho; aqui só a
# mensagem de requisição muda, nenhum outro log. /v/lookup não é token e
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
# Os access logs do proxy reverso ficam fora do Rails: gate de go-live.
require "rails/rack/logger"

module RequestLogPathMask
  TOKEN_PATH = %r{\A/([vr])/(?!lookup(?:[/?]|\z))[^/?]+}i

  def self.mask(path)
    path = path.to_s
    info, query = path.split("?", 2)
    normalized = normalize(info)
    return path unless normalized.match?(TOKEN_PATH)

    masked = normalized.sub(TOKEN_PATH, '/\1/[FILTERED]')
    query ? "#{masked}?#{query}" : masked
  end

  # Decodifica %XX (sem tratar "+" como espaço) e colapsa barras repetidas.
  def self.normalize(info)
    decoded = info.to_s.gsub(/%([0-9a-fA-F]{2})/) { $1.hex.chr }.scrub("")
    decoded.squeeze("/")
  end

  private

  def started_request_message(request)
    path = request.filtered_path
    masked = RequestLogPathMask.mask(path)
    message = super
    masked == path ? message : message.sub(%("#{path}"), %("#{masked}"))
  end
end

Rails::Rack::Logger.prepend(RequestLogPathMask)
