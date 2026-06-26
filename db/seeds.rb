# Seeds de desenvolvimento. Idempotente: `bin/rails db:seed` pode rodar N vezes.
#
# Cria o usuário de acesso ao Admin Console em dev (ver apps/admin/.env.example):
#   Acesso: http://localhost:5174/admin/ → login dev@local / dev-password
#
# Usuário SIMPLES de propósito (sem membership platform_operator): operador exige
# MFA/TOTP a cada login (ADR-0022), o que inviabiliza o login só com senha em dev.
# Login por senha de não-operador retorna 201 e o console resolve escopo sozinho.
#
# NUNCA roda em produção — senha fixa é só para ambiente local.
if Rails.env.production?
  warn "[seeds] pulando: seeds de dev não rodam em produção"
else
  email    = ENV.fetch("DEV_USER_EMAIL", "dev@local")
  password = ENV.fetch("DEV_USER_PASSWORD", "dev-password")

  user = User.find_or_initialize_by(email_address: email)
  user.password = password
  user.save!

  puts "[seeds] usuário de dev pronto: #{user.email_address} (id=#{user.id}) — senha: #{password}"
end
