# E-mails da ouvidoria (ADR 0051). Só datas e contagens: nunca protocolo,
# texto, pessoa, unidade nem link com id — o texto manda abrir o painel.
class OmbudsmanMailer < ApplicationMailer
  def anonymous_cap(to:, date:, count:)
    @date = date.strftime("%d/%m/%Y")
    @count = count
    mail(to: to, subject: "[rota-saúde] Teto diário da denúncia anônima atingido")
  end

  def daily_summary(to:, date:, red:, yellow:)
    @date = date.strftime("%d/%m/%Y")
    @red = red
    @yellow = yellow
    mail(to: to, subject: "[rota-saúde] Resumo diário de prazos da ouvidoria")
  end

  def responder_summary(to:, date:, pending:, red:, yellow:)
    @date = date.strftime("%d/%m/%Y")
    @pending = pending
    @red = red
    @yellow = yellow
    mail(to: to, subject: "[rota-saúde] Seus encaminhamentos da ouvidoria")
  end
end
