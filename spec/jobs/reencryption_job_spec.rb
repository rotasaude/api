# Smoke do ReencryptionJob: cobre o caminho do EachCityJob (uma passada por
# cidade ATIVA) e verifica que cada target conta as linhas tocadas.
# Não testa "rotação real" entre chaves — isso exigiria injetar prior_keys
# mid-suite, fora deste escopo.
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

  it "executa sem levantar e conta linhas re-encriptadas por target (sem MunicipalityChannel, D9)" do
    User.create!(email_address: "rotate@example.org", password: "secret123", otp_secret: "S3CR3T")
    Conversation.create!(phone: "+551199999", state: :greeting)

    stats = call_body

    expect(stats.keys).to match_array(%w[User Conversation InboundMessage Consent Author])
    expect(stats["User"]).to be >= 1
    expect(stats["Conversation"]).to be >= 1
  end

  it "limita target via :only" do
    User.create!(email_address: "scoped@example.org", password: "secret123", otp_secret: "X")

    stats = call_body(only: [:user])
    expect(stats.keys).to eq(["User"])
    expect(stats["User"]).to be >= 1
  end

  # "Idempotente — re-rodar com a mesma chave é no-op funcional" (comment atop
  # reencryption_job.rb): reassigning the SAME plaintext leaves the record
  # unchanged (record.changed? is false), so save! issues no UPDATE and
  # updated_at does not move — confirmed empirically against a real city
  # database. Side effects on the row are therefore NOT a valid signal of
  # "this city was visited" here; instead we observe EachCityJob's own
  # per-city dispatch (CityConnection.with(city) { super(...) }) directly.
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
