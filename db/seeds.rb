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
end
