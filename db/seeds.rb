# Seeds de desenvolvimento. Idempotente: `bin/rails db:seed` pode rodar N vezes.
#
# Recria a BASELINE mínima de dev que o `start.sh --reset` apaga (o bootstrap
# carrega `db/structure.sql`, que é schema-only — zero dados):
#
#   - Município "Curitiba Demo" .................... tenant de dev
#   - admin@curitiba.demo / dev-password .......... municipal_admin em Curitiba
#       → Dashboard  (http://localhost:5175/dashboard/)
#   - dev@local / dev-password .................... platform_operator + MFA
#       → Admin Console (http://localhost:5174/admin/), menu completo de Setup
#   - Demo ponta-a-ponta de Curitiba .............. canal WhatsApp + protocolo
#       ATIVO (triage-respiratoria) + triagem completa + relatório (painel
#       Relatórios do dashboard + link público WPDA)
#
# Operador exige MFA/TOTP a cada login (ADR-0022). Em dev usamos um `otp_secret`
# FIXO (override por env) para que a entrada no seu autenticador continue válida
# após cada reset — caso contrário você teria que re-enrolar toda vez.
#
# NUNCA roda em produção — senhas e segredo fixos são só para ambiente local.
if Rails.env.production?
  warn "[seeds] pulando: seeds de dev não rodam em produção"
else
  password = ENV.fetch("DEV_USER_PASSWORD", "dev-password")

  # ── Município de dev ────────────────────────────────────────────────────────
  curitiba = Municipality.find_or_initialize_by(slug: "curitiba")
  curitiba.update!(name: "Curitiba Demo", uf: "PR", status: "active")

  # ── Usuário municipal (Dashboard) ───────────────────────────────────────────
  muni_admin = User.find_or_initialize_by(email_address: "admin@curitiba.demo")
  muni_admin.password = password
  muni_admin.save!
  Membership.find_or_create_by!(user: muni_admin, municipality: curitiba, role: "municipal_admin") do |m|
    m.granted_at = Time.current
  end

  # ── Operador de plataforma (Admin Console) + MFA ────────────────────────────
  # otp_secret fixo (dev) para o autenticador sobreviver a resets. Só é setado
  # quando o operador ainda não tem MFA (não clobbera um segredo já existente).
  operator = User.find_or_initialize_by(email_address: "dev@local")
  operator.password = password
  unless operator.otp_enabled? && operator.otp_secret.present?
    operator.otp_secret  = ENV.fetch("DEV_OPERATOR_OTP_SECRET", "TQLRHWIAKEISPIW6YY3IAKGCLVNPF4EV")
    operator.otp_enabled = true
  end
  operator.save!
  Membership.find_or_create_by!(user: operator, role: "platform_operator", municipality_id: nil) do |m|
    m.granted_at = Time.current
  end

  puts "[seeds] baseline de dev pronta:"
  puts "  município ... #{curitiba.name} (#{curitiba.slug}/#{curitiba.uf}, #{curitiba.status})"
  puts "  municipal ... #{muni_admin.email_address} / #{password}  → dashboard"
  puts "  operador .... #{operator.email_address} / #{password} + MFA (otp_secret fixo)  → admin console"

  # ── Demo ponta-a-ponta de Curitiba ──────────────────────────────────────────
  # Canal WhatsApp + protocolo ATIVO (nome default do runtime) + triagem completa
  # + relatório. Dá dados para o runtime de triagem, o painel Relatórios (F-04.6)
  # e o relatório público (WPDA). Sob a conexão admin (BYPASSRLS) porque
  # conversations/triages/protocol_definitions são RLS-enforced e o seed roda sem
  # SET LOCAL. Idempotente.
  ApplicationRecord.connected_to(role: :admin) do
    channel = MunicipalityChannel.find_or_create_by!(phone_number_id: "PNID-CURITIBA-DEV") do |c|
      c.municipality_id       = curitiba.id
      c.waba_id               = "WABA-CURITIBA-DEV"
      c.display_phone_number  = "+5541999990000"
      c.access_token          = "DEV-WHATSAPP-TOKEN"
      c.active                = true
    end

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
    protocol = ProtocolDefinition.find_or_create_by!(name: "triage-respiratoria", municipality_id: curitiba.id, version: 1) do |p|
      p.status     = "active"
      p.definition = protocol_defn
    end

    # state "consented": a pessoa consentiu e concluiu a triagem — é o estado que
    # os painéis live/funil de Conversas contam (o enum tem "completed", mas o
    # funil só conta greeting/awaiting_consent/consented; com "completed" a demo
    # apareceria zerada). created_at ~5 min antes de completed_at para o KPI
    # avgToCompleteMin exibir uma duração realista, não ~0.
    convo  = Conversation.find_or_create_by!(municipality_id: curitiba.id, phone: "+5541999990001") { |c| c.state = "consented" }
    triage = Triage.where(conversation_id: convo.id, protocol_definition_id: protocol.id).first
    triage ||= Triage.create!(
      conversation: convo, protocol_definition: protocol, protocol_name: "triage-respiratoria",
      municipality_id: curitiba.id, status: "completed", tier: "alta", priority: 1,
      created_at: 5.minutes.ago, completed_at: Time.current,
      answers: { "tosse" => "true", "febre" => "true" },
      outcome: { "status" => "terminal", "tier" => "alta", "priority" => 1,
                 "trail" => [ { "step" => "tosse", "answer" => "true" }, { "step" => "febre", "answer" => "true" } ] }
    )
    GenerateReportJob.new.handle(triage_id: triage.id, status: "terminal", tier: "alta", priority: 1)
    report = ReportSnapshot.find_by(triage_id: triage.id)

    puts "  canal ....... #{channel.phone_number_id} (active)"
    puts "  protocolo ... #{protocol.name} v#{protocol.version} (#{protocol.status})"
    puts "  relatório ... #{report&.url}"
  end
end
