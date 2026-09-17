# Convite do mantenedor (spec §6). É o ÚNICO caminho fora da API, e é assim de
# propósito: o primeiro mantenedor de cada ambiente não tem quem o convide.
#
# Imprime a URL do convite porque nesta fatia não há mailer: o link é entregue
# fora de banda por quem rodou a task. O e-mail sai MASCARADO, como em
# city:invite_admin — contexto suficiente sem ecoar o endereço no terminal.
namespace :maintainer do
  mask_email = lambda do |address|
    local, _, domain = address.to_s.partition("@")
    "#{local[0]}***@#{domain}"
  end

  desc "Convida (ou reconvida) um mantenedor da API de manutenção. Uso: maintainer:invite[email]"
  task :invite, [ :email ] => :environment do |_t, args|
    unless MaintenanceApi.enabled?
      abort "[maintainer:invite] a API de manutenção não está ligada neste ambiente (#{Rails.env})"
    end

    email = args[:email].to_s.strip.downcase
    abort "uso: rails 'maintainer:invite[email]'" if email.blank?
    abort "[maintainer:invite] e-mail inválido" unless email.match?(URI::MailTo::EMAIL_REGEXP)

    maintainer = Maintainer.find_or_initialize_by(email_address: email)
    if maintainer.persisted? && !maintainer.active?
      abort "[maintainer:invite] #{mask_email.call(email)} está desativado — reative antes de reconvidar"
    end

    invitation = nil
    token = nil
    PlatformRecord.transaction do
      maintainer.save!
      # Reconvite zera senha e TOTP: quem perdeu o dispositivo recomeça o
      # cadastro inteiro.
      maintainer.update!(password: nil, otp_secret: nil, otp_enabled_at: nil, otp_recovery_codes: [],
                         failed_attempts: 0, locked_until: nil)
      maintainer.maintainer_sessions.destroy_all
      # Convite é EXCLUSIVO (fix round 1): um convite pendente antigo deixa de
      # valer assim que este novo é emitido — "usado" aqui inclui "superado".
      MaintainerInvitation.invalidate_pending_for!(maintainer)
      invitation, token = MaintainerInvitation.issue!(maintainer: maintainer)
      MaintenanceAudit.record("maintenance.maintainer.invited", outcome: "ok", module_name: "maintainer",
                              maintainer_id: maintainer.id, credential: { "kind" => "rake" },
                              invitation_id: invitation.id)
    end

    origin = ENV.fetch("MAINTENANCE_FRONTEND_ORIGIN", "https://maintenance.#{Rails.env}.rotasaude.com.br")
    puts "[maintainer:invite] #{mask_email.call(email)} → convite válido por #{MaintainerInvitation::TTL.inspect}"
    # Fragmento (#), não path: o navegador NUNCA envia o fragmento ao servidor,
    # então o token não aparece em nenhum log de acesso quando o link é aberto
    # (fix round 1 — o mesmo motivo pelo qual a API lê o token do corpo).
    puts "[maintainer:invite] #{origin}/invitations##{token}"
  end
end
