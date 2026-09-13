# Smoke do ReencryptionJob: cobre o caminho do EachCityJob (uma passada por
# cidade ATIVA) e conta quantas linhas cada target ITERA. Não prova
# re-encriptação de fato — ver a rotação real abaixo (pending, R41).
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

  # C1 (fix round 1 review): reencryption_job.rb:48 does `record[attr] =
  # record[attr]` to mark the attribute dirty before save! — but reassigning
  # the SAME decrypted plaintext does NOT dirty an encrypted attribute
  # (confirmed empirically: record.changed? is false), so save! issues no
  # UPDATE. After a real key rotation ([old, new] -> new becomes primary),
  # NOTHING gets re-encrypted: the row stays under the OLD key forever and
  # becomes unreadable once the old key is retired. Fixed by `record.encrypt`
  # (app fix goes in the final fix wave, R41) — this example must fail today
  # and turn green once that lands.
  it "re-encrypts under the new primary key after a rotation" do
    pending "bug de app: reencryption_job.rb:48 não suja o registro; rotação sem efeito (R41)"

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

  # "Idempotente — re-rodar com a mesma chave é no-op funcional" (comment atop
  # reencryption_job.rb): reassigning the SAME plaintext leaves the record
  # unchanged (record.changed? is false), so save! issues no UPDATE and
  # updated_at does not move — confirmed empirically against a real city
  # database. Side effects on the row are therefore NOT a valid signal of
  # "this city was visited" here; instead we observe EachCityJob's own
  # per-city dispatch (CityConnection.with(city) { super(...) }) directly.
  # Once R41 is fixed, these two examples should additionally assert the
  # ciphertext changed in EACH city's own database (the same shape as the
  # rotation example above, per city), since `record.encrypt` will then make
  # every visited row observably re-encrypted.
  it "roda uma vez por cidade ATIVA (EachCityJob): visita AMBAS as cidades" do
    city_b = create(:city, database_url: city_database_url("rota_saude_test_city_b"), status: "active")
    CityConnection.with(city_a) { User.create!(email_address: "a@example.org", password: "secret123", otp_secret: "S3CR3T") }
    CityConnection.with(city_b) { User.create!(email_address: "b@example.org", password: "secret123", otp_secret: "S3CR3T") }

    visited = []
    allow(CityConnection).to receive(:with).and_wrap_original do |original, city, &block|
      visited << city.slug
      original.call(city, &block)
    end

    described_class.new.perform(only: [:user])

    expect(visited).to include(city_a.slug, city_b.slug)
  end

  it "não visita uma cidade que não está active" do
    active_slug = city_a.slug
    suspended = create(:city, database_url: city_database_url("rota_saude_test_city_b"), status: "suspended")

    visited = []
    allow(CityConnection).to receive(:with).and_wrap_original do |original, city, &block|
      visited << city.slug
      original.call(city, &block)
    end

    described_class.new.perform(only: [:user])

    expect(visited).to include(active_slug)
    expect(visited).not_to include(suspended.slug)
  end
end
