require "rails_helper"

# Boot guard (Ruling R33). Two PRODUCTION boot blockers passed without any test
# because nothing in the project eager loads (development: eager_load = false;
# test: eager_load = ENV["CI"].present?):
#   - PlatformRecord.connects_to :platform with no `platform` stanza in production;
#   - config/storage.yml missing -> ActiveStorage raises during eager load.
#
# Rails::Application#eager_load! eager loads every autoloader
# (Rails.autoloaders.each(&:eager_load)), which loads ActiveStorage::Blob and
# runs its on_load hook — the one that raises without config/storage.yml. It
# does so regardless of config.eager_load / ENV["CI"].
RSpec.describe "Boot guard" do
  it "eager loads the application without raising" do
    expect { Rails.application.eager_load! }.not_to raise_error
  end

  describe "production stanzas of config/database.yml" do
    # database.yml's production ERB uses ENV.fetch without defaults for the
    # passwords; provide them (and the URLs) only inside these examples.
    before do
      stub_const("ENV", ENV.to_h.merge(
        "DATABASE_URL" => "postgres://db.internal:5432/rota_saude_production",
        "PLATFORM_DATABASE_URL" => "postgres://db.internal:5432/rota_saude_platform_production",
        "ROTA_APP_PASSWORD" => "app-secret",
        "ROTA_ADMIN_PASSWORD" => "admin-secret",
        "ROTA_PLATFORM_PASSWORD" => "platform-secret"
      ).except("CITY_UNSET_DATABASE_URL"))
    end

    # Resolved without connecting.
    def production_configs
      raw = ActiveSupport::ConfigurationFile.parse(Rails.root.join("config/database.yml"))
      ActiveRecord::DatabaseConfigurations.new(raw).configs_for(env_name: "production", include_hidden: true)
    end

    # Catches a new connects_to target declared for test with no production stanza.
    # Derived from the test configurations, not hardcoded.
    it "declares a production connection for every test connection" do
      test_names = ActiveRecord::Base.configurations
        .configs_for(env_name: "test", include_hidden: true)
        .map(&:name)
      expect(test_names).not_to be_empty

      production_names = production_configs.map(&:name)
      test_names.each do |name|
        expect(production_names).to include(name), "production has no `#{name}` stanza"
      end
    end

    # Covers every production connection, including those with no test stanza
    # (queue and cache: test uses the :test queue adapter and :null_store).
    it "resolves an adapter and a database for every production connection" do
      configs = production_configs
      expect(configs).not_to be_empty

      configs.each do |config|
        expect(config.adapter).to be_present, "production `#{config.name}` has no adapter"
        expect(config.database).to be_present, "production `#{config.name}` has no database"
      end
    end
  end
end
