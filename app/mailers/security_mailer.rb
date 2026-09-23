# Aviso ao dono da conta quando o SEGUNDO FATOR dele muda (spec
# 2026-09-23-authenticator-change-notice-design). Duas brechas ficaram abertas
# por desenho no autenticador pendente: numa conta sem TOTP, quem tem a senha
# cadastra o seu; numa conta com TOTP, senha + um código de recuperação trocam
# o segundo fator inteiro. Nenhuma das duas é visível para o dono — este
# e-mail é o que rompe o silêncio.
#
# Só valores simples (R42): deliver_later roda no worker, fora da conexão da
# cidade, onde um User (GlobalID) não desserializa.
#
# Nada de segredo aqui: nem otpauth, nem código, nem link (um e-mail de
# segurança com link é o formato que o phishing imita).
class SecurityMailer < ApplicationMailer
  KINDS = { "enrolled" => "Autenticador cadastrado", "replaced" => "Autenticador trocado" }.freeze

  def authenticator_changed(email_address:, kind:, city_name:, ip_address:, occurred_at:)
    subject = KINDS.fetch(kind) { raise ArgumentError, "kind desconhecido: #{kind.inspect}" }

    @replaced = kind == "replaced"
    @city_name = city_name
    @ip_address = ip_address
    # Normaliza para America/Sao_Paulo na exibição, como AlertMailer.
    @occurred_at = Time.iso8601(occurred_at).in_time_zone("America/Sao_Paulo")

    mail(to: email_address, subject: "[rota-saúde] #{subject}")
  end
end
