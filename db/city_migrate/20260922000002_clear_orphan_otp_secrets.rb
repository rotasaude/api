# Remediação de dado (fix final do spec 2026-09-22-pending-authenticator-
# design, achado A1): o código ANTIGO (Mfa::Enroll, antes deste spec) gravava
# otp_secret e zerava otp_enabled NA MESMA chamada, então uma troca abandonada
# no meio deixava a conta com otp_secret presente e otp_enabled = false. Como
# User#mfa_enrolled? é `otp_enabled? && otp_secret.present?`, essa conta conta
# como NÃO cadastrada — e, nesse estado, POST /mfa/enroll não exige step-up
# (a guarda só vale para conta cadastrada): quem tem só a senha cadastra o
# próprio autenticador por cima do resto órfão. Conta conhecida nesse estado
# em dev: admin@curitiba.demo.
#
# Isto é remediação de DADO, não mudança de SCHEMA — nenhuma coluna nasce ou
# muda aqui, db/city_schema.rb só sobe de versão. Limpa o resto: a conta fica
# explicitamente SEM segundo fator (o que ela já era na prática, já que
# otp_enabled é false) em vez de carregar um segredo que ninguém confirmou.
#
# Irreversível: depois de limpo não há como saber qual segredo estava ali, nem
# um caminho de volta que fizesse sentido — ninguém confirmou aquele segredo,
# então não há "desfazer" a limpeza, só recomeçar o cadastro.
class ClearOrphanOtpSecrets < ActiveRecord::Migration[8.1]
  UPDATE_SQL = <<~SQL.freeze
    UPDATE users SET otp_secret = NULL, otp_recovery_codes = '[]'::jsonb
    WHERE otp_enabled = false AND otp_secret IS NOT NULL
  SQL

  def up
    execute UPDATE_SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
