# E-mails da ouvidoria (ADR 0051). Só datas e contagens: nunca protocolo,
# texto, pessoa, unidade nem link com id — o texto manda abrir o painel.
class OmbudsmanMailer < ApplicationMailer
  def anonymous_cap(to:, date:, count:)
    @date = date.strftime("%d/%m/%Y")
    @count = count
    mail(to: to, subject: "[rota-saúde] Teto diário da denúncia anônima atingido")
  end
end
