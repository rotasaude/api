require "rails_helper"

# Remediação de dado da migração de cidade 20260922000002 (fix final do spec
# do autenticador pendente): o código antigo (Mfa::Enroll) gravava otp_secret
# e zerava otp_enabled na MESMA chamada, então uma troca abandonada no meio
# deixava a conta com otp_secret presente e otp_enabled = false. Nesse estado
# User#mfa_enrolled? é false, então POST /mfa/enroll não exige step-up e quem
# tem só a senha cadastra o próprio autenticador sobre o resto órfão.
#
# Sem precedente de spec de migração que rode a migração em si (a única
# migração testada, 20260921000001, é testada executando a SQL extraída para
# uma constante — spec/models/protocol_activation_baseline_spec.rb — não há
# spec/services/city_schema_spec.rb equivalente para uma migração específica).
# Seguimos o mesmo caminho: `require` o arquivo da migração e executamos a SQL
# equivalente (a mesma constante que `up` chama) na conexão de TEST_CITY_A, já
# no schema corrente (o around global de spec/support/city_test_databases.rb
# já abre CityConnection.with(TEST_CITY_A)).
RSpec.describe "Clear orphan otp secrets migration (db/city_migrate/20260922000002)" do
  def run!
    require Rails.root.join("db/city_migrate/20260922000002_clear_orphan_otp_secrets.rb").to_s
    User.connection.execute(ClearOrphanOtpSecrets::UPDATE_SQL)
  end

  it "limpa otp_secret e otp_recovery_codes de uma conta com troca abandonada (otp_enabled false, secret presente)" do
    orphan = User.create!(email_address: "orphan-#{SecureRandom.hex(3)}@example.org", password: "secret123",
                           otp_secret: "ORPHANSECRET", otp_recovery_codes: [ "x" ], otp_enabled: false)

    run!

    orphan.reload
    expect(orphan.otp_secret).to be_nil
    expect(orphan.otp_recovery_codes).to eq([])
  end

  it "não toca numa conta cadastrada de verdade (otp_enabled true)" do
    enrolled = User.create!(email_address: "enrolled-#{SecureRandom.hex(3)}@example.org", password: "secret123",
                             otp_secret: "REALSECRET", otp_recovery_codes: [ "y" ], otp_enabled: true)

    run!

    enrolled.reload
    expect(enrolled.otp_secret).to eq("REALSECRET")
    expect(enrolled.otp_recovery_codes).to eq([ "y" ])
  end

  it "não toca numa conta sem segredo nenhum" do
    clean = User.create!(email_address: "clean-#{SecureRandom.hex(3)}@example.org", password: "secret123")

    run!

    clean.reload
    expect(clean.otp_secret).to be_nil
    expect(clean.otp_enabled).to be(false)
  end
end
