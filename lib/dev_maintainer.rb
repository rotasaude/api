require "rotp"

# Semente de dev do console de manutenção (apps/maintenance).
#
# Por que existe: o `db/seeds.rb` semeava o Operator (console de plataforma,
# host admin.*) e os usuários de cada cidade, mas nunca um Maintainer — e
# Maintainer é outra tabela de propósito (ver o comentário no topo do modelo:
# juntar as duas faria uma conta de console valer aqui). O único caminho para
# criar mantenedor era `rails 'maintainer:invite[email]'`, cujo aceite define
# senha e matricula TOTP fora de banda. Resultado em dev: contas de mantenedor
# existiam, mas com credenciais que só quem rodou o convite conhecia — ninguém
# conseguia entrar em apps/maintenance de forma reproduzível.
#
# Por que segredo FIXO: sem ele, cada reset do banco de dev obrigaria a
# reescanear o autenticador. Mesmo desenho do operador em db/seeds.rb — valor de
# dev, override por env, e NUNCA sobrescreve segredo de quem já tem o seu.
#
# O convite continua sendo o caminho de verdade e segue exercitado pelas specs
# de requisição de `/invitations`; esta classe não passa por ele de propósito,
# porque aceitar convite exige um token entregue fora de banda.
#
# Nada aqui serve a ambiente publicado; quem garante isso é o chamador
# (`db/seeds.rb`, guardado por `Rota.deployed?`).
class DevMaintainer
  OTP_SECRET_ENV = "DEV_MAINTAINER_OTP_SECRET".freeze
  DEFAULT_OTP_SECRET = "KZ3WQ4TBMJXW6ZDFKZ3WQ4TBMJXW6ZDF".freeze

  class << self
    # Idempotente: pode rodar a cada `db:seed`.
    def ensure!(email_address:, password:)
      maintainer = Maintainer.find_or_initialize_by(email_address: email_address)
      maintainer.password = password

      unless maintainer.enrolled?
        maintainer.otp_secret = ENV.fetch(OTP_SECRET_ENV, DEFAULT_OTP_SECRET)
        maintainer.otp_enabled_at = Time.current
      end

      # Uma conta travada por cinco senhas erradas, ou desativada num teste
      # anterior, é exatamente o estado em que a semente PRECISA devolver o
      # acesso — do contrário `db:seed` roda "com sucesso" e o login continua
      # recusando.
      maintainer.failed_attempts = 0
      maintainer.locked_until = nil
      maintainer.deactivated_at = nil

      maintainer.save!
      maintainer
    end

    def otpauth_uri(maintainer)
      ROTP::TOTP.new(maintainer.otp_secret, issuer: "Rota Saúde manutenção (dev)")
                .provisioning_uri(maintainer.email_address)
    end
  end
end
