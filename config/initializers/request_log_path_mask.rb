# O token de /v/<token> (conferência do documento clínico, ADR 0033) e o de
# /r/<token> (relatório do 19a) ficam no caminho, e a linha de requisição do
# Rails ("Started GET \"/v/<token>\" ...") os gravaria em claro no log de
# produção (nível info). Não é "só a página pública": o mesmo token abre
# /v/<token>/signed.pdf, o PDF assinado com o documento inteiro. O
# filter_parameters cobre o "Parameters:" mas não o caminho; aqui só a
# mensagem de requisição muda, nenhum outro log. /v/lookup não é token e
# segue legível.
#
# Os access logs do proxy reverso ficam fora do Rails: gate de go-live.
require "rails/rack/logger"

module RequestLogPathMask
  TOKEN_PATH = %r{\A/([vr])/(?!lookup(?:[/?]|\z))[^/?]+}

  def self.mask(path) = path.to_s.sub(TOKEN_PATH, '/\1/[FILTERED]')

  private

  def started_request_message(request)
    path = request.filtered_path
    masked = RequestLogPathMask.mask(path)
    message = super
    masked == path ? message : message.sub(%("#{path}"), %("#{masked}"))
  end
end

Rails::Rack::Logger.prepend(RequestLogPathMask)
