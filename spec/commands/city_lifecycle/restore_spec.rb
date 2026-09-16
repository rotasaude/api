require "rails_helper"
require "tmpdir"

# Restore é o inverso do Backup (spec §4). A armadilha que ele existe para
# fechar: dump restaurado numa cidade cujo encryption_key mudou devolve dado
# ILEGÍVEL SEM ERRO — por isso a guarda de digest vem ANTES de tocar o banco.
RSpec.describe CityLifecycle::Restore do
  self.use_transactional_tests = false

  let!(:city) { provision_city!(status: "active") }
  let(:dir) { Dir.mktmpdir("city-restore") }

  after do
    cleanup_provisioned_city!(city)
  ensure
    FileUtils.rm_rf(dir)
  end

  # ATENÇÃO ao que a guarda realmente lê: SuspensionGuard.suspended_recently?
  # consulta o `occurred_at` do PlatformEvent "city.suspended" desta cidade —
  # NÃO o updated_at da City. Envelhecer o campo errado faria o exemplo de
  # recusa nunca ficar vermelho e o de sucesso passar pelo motivo errado.
  def suspend_at!(moment)
    PlatformEvent.where(name: "city.suspended").where("payload->>'city_id' = ?", city.id).delete_all
    PlatformEvent.create!(name: "city.suspended", occurred_at: moment, payload: { "city_id" => city.id })
    city.update!(status: "suspended")
  end

  # Dump de uma cidade com uma linha conhecida, já suspensa e FORA da
  # quarentena (o Restore exige as duas coisas).
  def dump_with_one_user!
    CityConnection.with(city) { User.create!(email_address: "servidora@cidade.gov.br", password: "secret123") }
    path = CityLifecycle::Backup.call(city: city, dir: dir).payload[:path]
    suspend_at!((CityLifecycle::SuspensionGuard::QUIET_PERIOD + 60.seconds).ago)
    path
  end

  it "restores a dump into its own city" do
    path = dump_with_one_user!
    CityConnection.with(city) { User.delete_all }

    result = described_class.call(city: city, path: path)

    expect(result.ok?).to be(true)
    emails = CityConnection.with(city) { User.pluck(:email_address) }
    expect(emails).to eq([ "servidora@cidade.gov.br" ])
  end

  it "refuses a city that is not suspended" do
    path = dump_with_one_user!
    city.update!(status: "active")

    result = described_class.call(city: city, path: path)

    expect(result.failure?).to be(true)
    expect(result.reason).to eq(:invalid_status)
  end

  it "refuses while the suspension is still within the quiet period" do
    path = dump_with_one_user!
    suspend_at!(Time.current)

    expect(described_class.call(city: city, path: path).reason).to eq(:suspension_too_recent)
  end

  it "refuses a dump taken under different key material, before touching the database" do
    path = dump_with_one_user!
    File.write("#{path}.key-digest", Digest::SHA256.hexdigest("outro material"))

    result = described_class.call(city: city, path: path)

    expect(result.reason).to eq(:key_mismatch)
    # Nada foi apagado: o banco continua com a linha do dump original.
    expect(CityConnection.with(city) { User.count }).to eq(1)
  end

  it "refuses a file that does not exist" do
    dump_with_one_user!
    expect(described_class.call(city: city, path: File.join(dir, "nao-existe.dump")).reason).to eq(:missing_file)
  end
end
