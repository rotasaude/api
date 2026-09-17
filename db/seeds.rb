# Seeds de desenvolvimento. Idempotente: `bin/rails db:seed` pode rodar N vezes.
#
#   - PLATAFORMA: operador dev@local / dev-password (Operator + MFA, otp_secret
#     fixo) — loga no console, host admin.* (Operators::SessionsController); e um
#     canal WhatsApp por cidade (CityChannel).
#   - CADA CIDADE (curitiba, maringa), dentro da conexão dela: admin@<slug>.demo /
#     dev-password como municipal_admin, o city_profile, um AlertRecipient de e-mail ativo,
#     protocolo ATIVO (triage-respiratoria), uma triagem completa e o relatório.
#     DDD, telefones, e-mails e canal diferem por cidade, para o isolamento ficar
#     visível fora da suíte.
#
# Pré-requisito: as cidades ativas no catálogo, com banco e schema —
# `bin/rails city:dev_baseline` (o start.sh já roda). Cidade ausente ou inativa é
# pulada com aviso.
#
# Operador exige MFA/TOTP a cada login (ADR-0011). Em dev usamos um `otp_secret`
# FIXO (override por env) para que a entrada no seu autenticador continue válida
# após cada reset — caso contrário você teria que re-enrolar toda vez.
#
# NUNCA roda em produção — senhas e segredo fixos são só para ambiente local.
if Rota.deployed?
  warn "[seeds] pulando: seeds de dev não rodam em ambiente publicado (#{Rails.env})"
else
  password = ENV.fetch("DEV_USER_PASSWORD", "dev-password")

  # ── Operador de plataforma + MFA ──────────────────────────────────────────────
  # otp_secret fixo (dev) para o autenticador sobreviver a resets. Só é setado
  # quando o operador ainda não tem MFA (não clobbera um segredo já existente).
  operator = Operator.find_or_initialize_by(email_address: "dev@local")
  operator.password = password
  unless operator.otp_enabled? && operator.otp_secret.present?
    operator.otp_secret  = ENV.fetch("DEV_OPERATOR_OTP_SECRET", "TQLRHWIAKEISPIW6YY3IAKGCLVNPF4EV")
    operator.otp_enabled = true
  end
  operator.save!
  puts "[seeds] operador .... #{operator.email_address} / #{password} + MFA (otp_secret fixo) → console admin.*"

  # Mesmo protocolo que o provisionamento semeia em rascunho (Plano 4); aqui ativo.
  protocol_defn = CityTemplates.protocol.fetch(:definition)

  { "curitiba" => %w[41 4106902], "maringa" => %w[44 4115200] }.each do |slug, (ddd, ibge_code)|
    city = City.find_by(slug: slug)
    if city.nil? || !city.servable?
      warn "[seeds] cidade '#{slug}' ausente ou não ativa no catálogo — pulada (rode bin/rails city:dev_baseline)"
      next
    end

    # ── Canal WhatsApp (plataforma) ─────────────────────────────────────────────
    tag = slug.upcase
    channel = CityChannel.find_or_create_by!(phone_number_id: "PNID-#{tag}-DEV") do |c|
      c.city                 = city
      c.waba_id              = "WABA-#{tag}-DEV"
      c.display_phone_number = "+55#{ddd}999990000"
      c.access_token         = "DEV-WHATSAPP-TOKEN-#{tag}"
      c.active               = true
    end

    Current.set(city: city) do
      CityConnection.with(city) do
        # ── Usuário municipal (Dashboard) ─────────────────────────────────────
        muni_admin = User.find_or_initialize_by(email_address: "admin@#{slug}.demo")
        muni_admin.password = password
        muni_admin.save!
        Membership.find_or_create_by!(user: muni_admin, role: "municipal_admin") do |m|
          m.granted_at = Time.current
        end

        # ── Identidade da cidade no banco dela (city_profile, Plano 4) ────────
        profile = CityProfile.current || CityProfile.new
        profile.update!(name: city.name, uf: city.uf, ibge_code: ibge_code)

        # ── Destinatário de alerta urgente (R37) ──────────────────────────────
        # DispatchMunicipalityAlertJob entrega ao primeiro AlertRecipient de email
        # ativo da cidade e levanta NoAlertRecipient sem nenhum. Um por cidade, no
        # banco dela. city_profile não carrega destino de alerta (Plano 4).
        alert_recipient = AlertRecipient.find_or_initialize_by(
          channel: "email", destination: ENV.fetch("DEV_ALERT_EMAIL", "alertas@#{slug}.demo")
        )
        alert_recipient.active = true
        alert_recipient.save!

        # ── Demo ponta-a-ponta ────────────────────────────────────────────────
        protocol = ProtocolDefinition.find_or_create_by!(name: "triage-respiratoria", version: 1) do |p|
          p.status     = "active"
          p.definition = protocol_defn
        end

        # state "consented": a pessoa consentiu e concluiu a triagem — é o estado
        # que os painéis live/funil de Conversas contam. created_at ~5 min antes
        # de completed_at para o KPI avgToCompleteMin exibir uma duração realista.
        convo  = Conversation.find_or_create_by!(phone: "+55#{ddd}999990001") { |c| c.state = "consented" }
        triage = Triage.where(conversation_id: convo.id, protocol_definition_id: protocol.id).first
        triage ||= Triage.create!(
          conversation: convo, protocol_definition: protocol, protocol_name: "triage-respiratoria",
          status: "completed", tier: "alta", priority: 1,
          created_at: 5.minutes.ago, completed_at: Time.current,
          answers: { "tosse" => "true", "febre" => "true" },
          outcome: { "status" => "terminal", "tier" => "alta", "priority" => 1,
                     "trail" => [ { "step" => "tosse", "answer" => "true" }, { "step" => "febre", "answer" => "true" } ] }
        )
        GenerateReportJob.new.handle(triage_id: triage.id, status: "terminal", tier: "alta", priority: 1)
        report = ReportSnapshot.find_by(triage_id: triage.id)

        puts "[seeds] cidade ...... #{city.name} (#{city.slug}/#{city.uf}, #{city.status})"
        puts "  perfil ...... #{profile.name}/#{profile.uf} IBGE #{profile.ibge_code}"
        puts "  municipal ... #{muni_admin.email_address} / #{password}  → dashboard"
        puts "  alerta ...... #{alert_recipient.destination} (email, active)"
        puts "  canal ....... #{channel.phone_number_id} (active)"
        puts "  protocolo ... #{protocol.name} v#{protocol.version} (#{protocol.status})"
        puts "  relatório ... #{report&.url}"
      end
    end
  end
end

# Dataset opcional e pesado dos painéis (todas as cidades de dev). Fora por
# padrão; o seed base fica enxuto. Ligue com SEED_DASHBOARD_DEMO=1 bin/rails db:seed
# (ou bin/rails db:seed:demo). Ver lib/dashboard_demo.rb.
if ENV["SEED_DASHBOARD_DEMO"] == "1" && !Rota.deployed?
  load Rails.root.join("db/seeds/dashboard_demo.rb")
end
