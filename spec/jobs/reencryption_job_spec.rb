# ReencryptionJob: conta as linhas ITERADAS por target, prova a re-encriptação
# real sob rotação de chave (R41) e, pelo EachCityJob, que o ciphertext muda no
# banco de CADA cidade ativa — e não no de uma cidade não ativa.
require "rails_helper"

RSpec.describe ReencryptionJob do
  let(:city_a) { create(:city, database_url: city_database_url("rota_saude_test_city_a")) }

  # ReencryptionJob prepends EachCityJob, cujo #perform não devolve o stats
  # hash do job (só agrega falhas ou levanta) — para inspecionar `stats` por
  # cidade, chamamos o corpo do job direto na conexão que o harness já abriu,
  # como 5b já fez para rebuild_dashboard_metrics_job_spec/reconcile_consents_job_spec.
  def call_body(**kwargs)
    described_class.instance_method(:perform).super_method.bind_call(described_class.new, **kwargs)
  end

  it "executa sem levantar e conta as linhas ITERADAS por target (sem MunicipalityChannel, D9)" do
    User.create!(email_address: "rotate@example.org", password: "secret123", otp_secret: "S3CR3T")
    Conversation.create!(phone: "+551199999", state: :greeting)

    stats = call_body

    expect(stats.keys).to match_array(%w[User Conversation InboundMessage Consent Author])
    expect(stats["User"]).to be >= 1
    expect(stats["Conversation"]).to be >= 1
  end

  it "conta apenas as linhas do target selecionado via :only (não prova re-encriptação)" do
    User.create!(email_address: "scoped@example.org", password: "secret123", otp_secret: "X")

    stats = call_body(only: [:user])
    expect(stats.keys).to eq(["User"])
    expect(stats["User"]).to be >= 1
  end

  # R41: `record[attr] = record[attr]` never dirtied an encrypted attribute, so
  # save! issued no UPDATE and a rotation re-encrypted nothing. The job now calls
  # record.encrypt, which rewrites the ciphertext under the current primary key.
  it "re-encrypts under the new primary key after a rotation" do
    old_only  = ActiveRecord::Encryption::DerivedSecretKeyProvider.new(["r41-old-key"])
    old_and_new = ActiveRecord::Encryption::DerivedSecretKeyProvider.new(["r41-old-key", "r41-new-key"])
    new_only  = ActiveRecord::Encryption::DerivedSecretKeyProvider.new(["r41-new-key"])

    user = ActiveRecord::Encryption.with_encryption_context(key_provider: old_only) do
      User.create!(email_address: "rot@example.org", password: "secret123", otp_secret: "S3CR3T-BEFORE")
    end

    raw_before = User.connection.select_value(
      User.sanitize_sql(["SELECT otp_secret FROM users WHERE id = ?", user.id])
    )

    # Rotation in progress: the job must be able to READ under the old key
    # (still in the list) and WRITE under the new one (last = primary).
    ActiveRecord::Encryption.with_encryption_context(key_provider: old_and_new) do
      call_body(only: [:user])
    end

    raw_after = User.connection.select_value(
      User.sanitize_sql(["SELECT otp_secret FROM users WHERE id = ?", user.id])
    )
    expect(raw_after).not_to eq(raw_before)

    decrypted = ActiveRecord::Encryption.with_encryption_context(key_provider: new_only) do
      User.find(user.id).otp_secret
    end
    expect(decrypted).to eq("S3CR3T-BEFORE")
  end

  # Per-city effect (R41 follow-up): EachCityJob must re-encrypt in EACH active
  # city's own database. city_a/city_b are random-slug Cities — separate
  # sessions (see spec/support/city_test_databases.rb) — so every read goes
  # through that city's own CityConnection.with.
  describe "per city (EachCityJob)" do
    let(:old_only)    { ActiveRecord::Encryption::DerivedSecretKeyProvider.new(["r41-old-key"]) }
    let(:old_and_new) { ActiveRecord::Encryption::DerivedSecretKeyProvider.new(["r41-old-key", "r41-new-key"]) }
    let(:new_only)    { ActiveRecord::Encryption::DerivedSecretKeyProvider.new(["r41-new-key"]) }

    def create_user_under_old_key(city, email)
      CityConnection.with(city) do
        ActiveRecord::Encryption.with_encryption_context(key_provider: old_only) do
          User.create!(email_address: email, password: "secret123", otp_secret: "S3CR3T-#{email}")
        end
      end
    end

    def raw_otp_secret(city, user)
      CityConnection.with(city) do
        User.connection.select_value(User.sanitize_sql(["SELECT otp_secret FROM users WHERE id = ?", user.id]))
      end
    end

    def decrypted_under_new_key(city, user)
      CityConnection.with(city) do
        ActiveRecord::Encryption.with_encryption_context(key_provider: new_only) { User.find(user.id).otp_secret }
      end
    end

    it "re-encrypts in the database of EVERY active city" do
      city_b = create(:city, database_url: city_database_url("rota_saude_test_city_b"), status: "active")
      user_a = create_user_under_old_key(city_a, "a@example.org")
      user_b = create_user_under_old_key(city_b, "b@example.org")
      raw_a_before = raw_otp_secret(city_a, user_a)
      raw_b_before = raw_otp_secret(city_b, user_b)

      ActiveRecord::Encryption.with_encryption_context(key_provider: old_and_new) do
        described_class.new.perform(only: [:user])
      end

      expect(raw_otp_secret(city_a, user_a)).not_to eq(raw_a_before)
      expect(raw_otp_secret(city_b, user_b)).not_to eq(raw_b_before)
      expect(decrypted_under_new_key(city_a, user_a)).to eq("S3CR3T-a@example.org")
      expect(decrypted_under_new_key(city_b, user_b)).to eq("S3CR3T-b@example.org")
    end

    it "does not touch the database of a city that is not active" do
      suspended = create(:city, database_url: city_database_url("rota_saude_test_city_b"), status: "suspended")
      user_a = create_user_under_old_key(city_a, "a@example.org")
      user_s = create_user_under_old_key(suspended, "s@example.org")
      raw_a_before = raw_otp_secret(city_a, user_a)
      raw_s_before = raw_otp_secret(suspended, user_s)

      ActiveRecord::Encryption.with_encryption_context(key_provider: old_and_new) do
        described_class.new.perform(only: [:user])
      end

      expect(raw_otp_secret(city_a, user_a)).not_to eq(raw_a_before)
      expect(raw_otp_secret(suspended, user_s)).to eq(raw_s_before)
    end
  end
end
