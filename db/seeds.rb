# Seeds de desenvolvimento. Idempotente: `bin/rails db:seed` pode rodar N vezes.
#
# ADAPTAÇÃO MÍNIMA ao banco por cidade (Plano 2, lote 5b). A baseline de dev de
# verdade — operador entrando na cidade por grant, provisionamento em duas
# fases — é território do Plano 3 / Esboço B. O que este arquivo faz hoje:
#
#   - PLATAFORMA: operador dev@local / dev-password (Operator + MFA) e o canal
#     WhatsApp da cidade de dev (CityChannel). O operador ainda NÃO loga: o
#     fluxo de operador na plataforma é o Plano 3.
#   - CIDADE (dentro de CityConnection.with): admin@curitiba.demo / dev-password
#     como municipal_admin (→ Dashboard), um AlertRecipient de e-mail ativo
#     (destino de triage urgente), protocolo ATIVO (triage-respiratoria),
#     triagem completa e relatório (painel Relatórios + link público WPDA).
#
# Pré-requisito: a cidade de dev (SEED_CITY_SLUG, default "curitiba") existir no
# catálogo com status "active" e com o schema de cidade carregado no banco dela
# (city:create + city:load_schema; o provisionamento real é o Plano 4). Sem isso,
# a parte da cidade é pulada com aviso.
#
# Operador exige MFA/TOTP a cada login (ADR-0011). Em dev usamos um `otp_secret`
# FIXO (override por env) para que a entrada no seu autenticador continue válida
# após cada reset — caso contrário você teria que re-enrolar toda vez.
#
# NUNCA roda em produção — senhas e segredo fixos são só para ambiente local.
if Rails.env.production?
  warn "[seeds] pulando: seeds de dev não rodam em produção"
else
  password = ENV.fetch("DEV_USER_PASSWORD", "dev-password")

  # ── Operador de plataforma + MFA ────────────────────────────────────────────
  # otp_secret fixo (dev) para o autenticador sobreviver a resets. Só é setado
  # quando o operador ainda não tem MFA (não clobbera um segredo já existente).
  operator = Operator.find_or_initialize_by(email_address: "dev@local")
  operator.password = password
  unless operator.otp_enabled? && operator.otp_secret.present?
    operator.otp_secret  = ENV.fetch("DEV_OPERATOR_OTP_SECRET", "TQLRHWIAKEISPIW6YY3IAKGCLVNPF4EV")
    operator.otp_enabled = true
  end
  operator.save!
  puts "[seeds] operador .... #{operator.email_address} / #{password} + MFA (otp_secret fixo) — login só no Plano 3"

  slug = ENV.fetch("SEED_CITY_SLUG", "curitiba")
  city = City.find_by(slug: slug)

  if city.nil? || !city.servable?
    warn "[seeds] cidade '#{slug}' ausente ou não ativa no catálogo — parte da cidade pulada " \
         "(registre com city:create, carregue o schema com city:load_schema e ative a cidade)"
  else
    # ── Canal WhatsApp (plataforma) ───────────────────────────────────────────
    channel = CityChannel.find_or_create_by!(phone_number_id: "PNID-CURITIBA-DEV") do |c|
      c.city                  = city
      c.waba_id               = "WABA-CURITIBA-DEV"
      c.display_phone_number  = "+5541999990000"
      c.access_token          = "DEV-WHATSAPP-TOKEN"
      c.active                = true
    end

    Current.set(city: city) do
      CityConnection.with(city) do
        # ── Usuário municipal (Dashboard) ─────────────────────────────────────
        muni_admin = User.find_or_initialize_by(email_address: "admin@curitiba.demo")
        muni_admin.password = password
        muni_admin.save!
        Membership.find_or_create_by!(user: muni_admin, role: "municipal_admin") do |m|
          m.granted_at = Time.current
        end

        # ── Destinatário de alerta urgente (R37) ──────────────────────────────
        # DispatchMunicipalityAlertJob entrega ao primeiro AlertRecipient de
        # e-mail ativo da cidade e levanta NoAlertRecipient sem nenhum — sem
        # esta linha, todo triage.urgent de dev falharia. Um por cidade, no
        # banco dela; o city_profile (Plano 4) substitui.
        alert_recipient = AlertRecipient.find_or_initialize_by(
          channel: "email", destination: ENV.fetch("DEV_ALERT_EMAIL", "alertas@#{city.slug}.demo")
        )
        alert_recipient.active = true
        alert_recipient.save!

        # ── Demo ponta-a-ponta ────────────────────────────────────────────────
        protocol_defn = {
          "name" => "triage-respiratoria", "version" => 1, "start_step_id" => "tosse",
          "steps" => [
            { "id" => "tosse", "prompt" => "Você está com tosse?", "answer_type" => "boolean",
              "branches" => { "true" => "febre", "false" => nil }, "weights" => { "true" => 3, "false" => 0 } },
            { "id" => "febre", "prompt" => "Está com febre alta?", "answer_type" => "boolean",
              "branches" => { "true" => nil, "false" => nil }, "weights" => { "true" => 5, "false" => 0 } }
          ],
          "scoring" => { "type" => "weighted", "thresholds" => { "baixa" => 0, "alta" => 5 },
                         "priority_map" => { "baixa" => 9, "alta" => 1 } },
          "recommendations" => {
            "alta"  => { "title" => "Procure atendimento hoje",
                         "body" => "Prioridade alta. Vá à UPA/unidade mais próxima ainda hoje. Falta de ar, dor no peito ou lábios roxos → 192." },
            "baixa" => { "title" => "Cuidados em casa",
                         "body" => "Repouso e hidratação. Se piorar ou persistir por mais de 3 dias, procure sua unidade de saúde." }
          }
        }
        protocol = ProtocolDefinition.find_or_create_by!(name: "triage-respiratoria", version: 1) do |p|
          p.status     = "active"
          p.definition = protocol_defn
        end

        # state "consented": a pessoa consentiu e concluiu a triagem — é o estado
        # que os painéis live/funil de Conversas contam. created_at ~5 min antes
        # de completed_at para o KPI avgToCompleteMin exibir uma duração realista.
        convo  = Conversation.find_or_create_by!(phone: "+5541999990001") { |c| c.state = "consented" }
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
        puts "  municipal ... #{muni_admin.email_address} / #{password}  → dashboard"
        puts "  alerta ...... #{alert_recipient.destination} (email, active)"
        puts "  canal ....... #{channel.phone_number_id} (active)"
        puts "  protocolo ... #{protocol.name} v#{protocol.version} (#{protocol.status})"
        puts "  relatório ... #{report&.url}"
      end
    end
  end
end

# Optional heavy demo dataset for the dashboard. Off by default; base seed stays
# lean. Enable with SEED_DASHBOARD_DEMO=1 bin/rails db:seed  (or bin/rails db:seed:demo).
# PENDENTE: o dataset ainda é do schema pré-corte e falha alto (Plano 3 / Esboço B).
if ENV["SEED_DASHBOARD_DEMO"] == "1" && !Rails.env.production?
  load Rails.root.join("db/seeds/dashboard_demo.rb")
end
