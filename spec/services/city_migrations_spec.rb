require "rails_helper"

# city:migrate:all (spec banco-por-cidade §4): migra toda cidade active/suspended,
# registra a versão no catálogo e falha ALTO no fim se alguma ficar para trás —
# sem deixar uma cidade quebrada impedir as outras.
RSpec.describe CityMigrations do
  self.use_transactional_tests = false

  let(:scratch) { ScratchDatabases.new_name }
  let(:created_slugs) { [] }

  after do
    City.where(slug: created_slugs).delete_all
    ScratchDatabases.drop!(scratch)
  end

  def catalog_city(status:, database:)
    slug = "mig#{SecureRandom.hex(4)}"
    created_slugs << slug
    City.create!(slug: slug, name: "Migra", status: status, database_url: ScratchDatabases.url(database),
                 encryption_key: SecureRandom.hex(32))
  end

  it "migrates a city and records the version in the catalog" do
    ScratchDatabases.create!(scratch)
    city = catalog_city(status: "active", database: scratch)

    expect(described_class.run(city)).to eq(CitySchema.expected_version)
    expect(city.reload.schema_version).to eq(CitySchema.expected_version.to_s)
  end

  it "keeps going after a broken city and fails loud at the end, naming only the cities left behind" do
    ScratchDatabases.create!(scratch)
    healthy  = catalog_city(status: "suspended", database: scratch)
    broken   = catalog_city(status: "active", database: "#{ScratchDatabases::PREFIX}missing#{SecureRandom.hex(3)}")
    skipped  = catalog_city(status: "provisioning", database: "#{ScratchDatabases::PREFIX}missing#{SecureRandom.hex(3)}")
    archived = catalog_city(status: "archived", database: "#{ScratchDatabases::PREFIX}missing#{SecureRandom.hex(3)}")
    out = StringIO.new

    expect { described_class.run_all(out: out) }.to raise_error(CityMigrations::Failed) { |error|
      expect(error.failures.keys).to eq([ broken.slug ])
      expect(error.message).to include(broken.slug)
    }

    expect(healthy.reload.schema_version).to eq(CitySchema.expected_version.to_s)
    expect([ broken, skipped, archived ].map { |c| c.reload.schema_version }).to eq([ nil, nil, nil ])
    expect(out.string).to include("#{healthy.slug} → #{CitySchema.expected_version}").and include("#{broken.slug} FALHOU")
  end

  it "does not raise when every city migrates" do
    ScratchDatabases.create!(scratch)
    catalog_city(status: "active", database: scratch)

    expect { described_class.run_all(out: StringIO.new) }.not_to raise_error
  end
end
