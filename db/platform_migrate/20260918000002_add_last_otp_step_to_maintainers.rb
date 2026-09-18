# I3: o passo de TOTP já consumido por este mantenedor.
#
# Um código vale 30 segundos e a tolerância de relógio (Mfa::Verify::DRIFT)
# deixa ~3 passos válidos ao mesmo tempo: sem isto, o código digitado no
# /session/challenge continuava valendo para o step-up que emite um token de 90
# dias, segundos depois. Guardar o PASSO (e não o código) é o que permite
# recusar a repetição sem nunca gravar o segredo.
#
# Só `maintainers`: User e Operator não mudam de comportamento nesta fatia.
class AddLastOtpStepToMaintainers < ActiveRecord::Migration[8.1]
  def change
    add_column :maintainers, :last_otp_step, :bigint
  end
end
