require "rails_helper"
require "tmpdir"

# Offboarding (spec banco-por-cidade §4): suspensa → dump final → archived → DROP.
# Caso nomeado da spec: offboarding de A não altera nada em B.
RSpec.describe CityLifecycle::Offboard do
  self.use_transactional_tests = false

  let!(:city_a) { provision_city!(status: "suspended") }
  let!(:city_b) { provision_city! }
  let(:dir) { Dir.mktmpdir("city-backups") }

  after do
    # cleanup_provisioned_city! already guarantees ITS OWN city's platform rows
    # are gone even if the drop itself fails (fix round 1); this still attempts
    # BOTH cities' cleanup before re-raising, so a failure on A never skips B's
    # cleanup the way a plain `.each` would.
    errors = [ city_a, city_b ].filter_map do |city|
      cleanup_provisioned_city!(city)
      nil
    rescue StandardError => e
      e
    end
    FileUtils.rm_rf(dir)
    raise errors.first if errors.any?
  end

  def role_can_connect?(city)
    PG.connect(city.database_url).close
    true
  rescue PG::ConnectionBad
    false
  end

  def channel_for(city)
    CityChannel.create!(city: city, phone_number_id: "PN-#{SecureRandom.hex(4)}", waba_id: "WABA",
                        display_phone_number: "+55 41 90000-0000", access_token: "tok", active: true)
  end

  it "dumps, archives and drops A, leaving B untouched" do
    CityConnection.with(city_b) { User.create!(email_address: "b@cidade-b.gov.br", password: "secret123") }
    channel_a, channel_b = channel_for(city_a), channel_for(city_b)
    CityGrants.issue(city: city_a, kind: "operator", subject_id: SecureRandom.uuid)
    CityGrants.issue(city: city_b, kind: "operator", subject_id: SecureRandom.uuid)

    result = described_class.call(city: city_a, backup_dir: dir)

    expect(result.ok?).to be(true)
    expect(File.exist?(result.payload[:backup_path])).to be(true)
    expect(city_a.reload.status).to eq("archived")
    expect(CityDatabase.exists?(slug: city_a.slug)).to be(false)
    expect(role_can_connect?(city_a)).to be(false)
    expect(channel_a.reload.active).to be(false)
    expect(CityGrant.where(city_id: city_a.id)).to be_empty
    expect(PlatformEvent.where(name: "city.archived").where("payload->>'city_id' = ?", city_a.id).pluck(:payload))
      .to eq([ { "city_id" => city_a.id, "backup" => File.basename(result.payload[:backup_path]) } ])

    expect(city_b.reload.status).to eq("active")
    expect(CityDatabase.exists?(slug: city_b.slug)).to be(true)
    expect(role_can_connect?(city_b)).to be(true)
    expect(channel_b.reload.active).to be(true)
    expect(CityGrant.where(city_id: city_b.id).count).to eq(1)
    CityConnection.with(city_b) { expect(User.pluck(:email_address)).to eq([ "b@cidade-b.gov.br" ]) }
  end

  it "refuses a city that is not suspended, dropping and dumping nothing" do
    result = described_class.call(city: city_b, backup_dir: dir)

    expect(result.reason).to eq(:invalid_status)
    expect(CityDatabase.exists?(slug: city_b.slug)).to be(true)
    expect(Dir.children(dir)).to be_empty
  end

  it "changes nothing when the final dump fails" do
    allow(CityLifecycle::Backup).to receive(:call).and_return(Result.fail(:backup_failed, message: "disco cheio"))

    result = described_class.call(city: city_a, backup_dir: dir)

    expect(result.reason).to eq(:backup_failed)
    expect(city_a.reload.status).to eq("suspended")
    expect(CityDatabase.exists?(slug: city_a.slug)).to be(true)
  end

  it "only repeats the drop for a city already archived" do
    described_class.call(city: city_a, backup_dir: dir)
    expect(CityLifecycle::Backup).not_to receive(:call)

    result = described_class.call(city: city_a.reload, backup_dir: dir)

    expect(result.ok?).to be(true)
    expect(result.payload[:backup_path]).to be_nil
    expect(CityDatabase.exists?(slug: city_a.slug)).to be(false)
  end
end
