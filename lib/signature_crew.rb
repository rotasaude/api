require "rotp"

# Semente de dev do ciclo assinado (plano 2026-09-23). Cria, DENTRO da conexão
# da cidade corrente, as quatro contas que o ciclo exige — autor, duas
# revisoras e publisher — com TOTP já pronto, e um rascunho (achado ou, na
# falta de um, criado na próxima versão livre) PELO command de autoria; e a
# dupla do atendimento (spec 2026-09-25 §6).
#
# Por que pelo command: `Protocols::SaveDraft` grava a ProtocolContribution do
# autor e o content_digest. É disso que as assinaturas dependem: quem editou
# não assina, e editar de novo invalida assinatura pelo digest. Um
# `ProtocolDefinition.create!` na mão produziria uma versão que parece certa e
# um estado de assinatura que não existe no domínio.
#
# Por que segredo FIXO: sem ele, cada reset do banco de dev obrigaria a
# reescanear quatro autenticadores. Mesmo desenho do operador em db/seeds.rb —
# valor de dev, override por env, e nunca sobrescreve segredo já existente.
# Nada aqui é para ambiente publicado; quem garante isso é o chamador
# (db/seeds.rb, guardado por Rota.deployed?).
class SignatureCrew
  PASSWORD_ENV = "DEV_USER_PASSWORD".freeze

  # Derivado do template (não um literal solto): se o template for renomeado,
  # a busca abaixo acompanha — um literal desatualizado faria ensure_draft
  # nunca achar a versão certa e SaveDraft reescrever a cada seed (ver F3).
  PROTOCOL_NAME = CityTemplates.protocol.fetch(:name)

  MEMBERS = [
    { email_prefix: "autor",     role: "protocol_author",    secret_env: "DEV_AUTHOR_OTP_SECRET",
      default_secret: "KRSXG5CTMVRXEZLUKRSXG5CTMVRXEZLU" },
    { email_prefix: "revisora1", role: "protocol_reviewer",  secret_env: "DEV_REVIEWER1_OTP_SECRET",
      default_secret: "MFRGGZDFMZTWQ2LKMFRGGZDFMZTWQ2LK" },
    { email_prefix: "revisora2", role: "protocol_reviewer",  secret_env: "DEV_REVIEWER2_OTP_SECRET",
      default_secret: "NBSWY3DPFQQFO33SNBSWY3DPFQQFO33S" },
    { email_prefix: "publisher", role: "protocol_publisher", secret_env: "DEV_PUBLISHER_OTP_SECRET",
      default_secret: "OBQXG43XN5ZGILLQOBQXG43XN5ZGILLQ" },
    { email_prefix: "profissional", role: "health_professional", secret_env: "DEV_PROFESSIONAL_OTP_SECRET",
      default_secret: "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ" },
    { email_prefix: "recepcao", role: "citizen_verifier", secret_env: "DEV_RECEPTION_OTP_SECRET",
      default_secret: "MZXW6YTBOIQHEZLDMVUXEZLTOQQGC3TE" }
  ].freeze

  class << self
    # Resumo: { accounts: [ { email:, role:, otpauth_uri: } ], draft: {...} | nil }
    def seed_current_city(slug:, password:)
      accounts = MEMBERS.map { |member| ensure_member(member, slug: slug, password: password) }
      { accounts: accounts, draft: ensure_draft(slug: slug) }
    end

    # Também usada pelo db/seeds.rb para dar TOTP ao admin municipal que ele
    # mesmo cria (a tela Equipe exige step-up para conceder papel).
    def ensure_totp(user, secret_env:, default_secret:)
      return user if user.mfa_enrolled?

      user.update!(otp_secret: ENV.fetch(secret_env, default_secret), otp_enabled: true)
      user
    end

    def otpauth_uri(user)
      ROTP::TOTP.new(user.otp_secret, issuer: "Rota Saúde (dev)").provisioning_uri(user.email_address)
    end

    private

    def ensure_member(member, slug:, password:)
      user = User.find_or_initialize_by(email_address: "#{member[:email_prefix]}@#{slug}.demo")
      user.password = password
      user.save!
      Membership.find_or_create_by!(user: user, role: member[:role]) { |m| m.granted_at = Time.current }
      ensure_totp(user, secret_env: member[:secret_env], default_secret: member[:default_secret])

      { email: user.email_address, role: member[:role], otpauth_uri: otpauth_uri(user) }
    end

    # O rascunho nasce do autor, pelo command. Já existindo UM rascunho de
    # verdade (status draft, qualquer versão), devolve-o sem reescrever:
    # reescrever mudaria o digest e derrubaria assinatura que você acabou de
    # coletar na mão. Não havendo, cria a PRÓXIMA versão livre — nunca a v2
    # fixa: em uma cidade com v1 published, v2 active e v3 in_review (por
    # exemplo), a próxima livre é a v4.
    def ensure_draft(slug:)
      author = User.find_by!(email_address: "autor@#{slug}.demo")
      existing_draft = ProtocolDefinition.find_by(name: PROTOCOL_NAME, status: "draft")
      return summarize(existing_draft) if existing_draft

      version = next_free_version
      result = Protocols::SaveDraft.call(definition: draft_definition(version), by: author)
      return nil unless result.ok?

      summarize(result.payload[:protocol_definition])
    end

    def next_free_version
      (ProtocolDefinition.where(name: PROTOCOL_NAME).maximum(:version) || 0) + 1
    end

    def summarize(record)
      { name: record.name, version: record.version, status: record.status }
    end

    # A definição vem do MESMO template que o provisionamento e o seed usam
    # (CityTemplates.protocol → config/city_templates/triage_respiratoria.json),
    # que já passa no portão. Só a versão muda, e o prompt do primeiro passo
    # ganha um sufixo para a versão ficar visível na tela.
    def draft_definition(version)
      definition = CityTemplates.protocol.fetch(:definition).deep_dup
      definition["version"] = version
      first_step = definition.fetch("steps").first
      first_step["prompt"] = "#{first_step['prompt']} (v#{version})"
      definition
    end
  end
end
