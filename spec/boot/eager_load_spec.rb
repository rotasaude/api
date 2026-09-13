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

  # Every connection declared for test must also be declared for production.
  # The list is derived from the test configurations, not hardcoded, so a new
  # connection added only to the test stanza fails here.
  it "declares, for every test connection, a production connection with an adapter and a database" do
    # database.yml's production ERB uses ENV.fetch without defaults for the
    # passwords; provide them (and the URLs) only inside this example.
    stub_const("ENV", ENV.to_h.merge(
      "DATABASE_URL" => "postgres://db.internal:5432/rota_saude_production",
      "PLATFORM_DATABASE_URL" => "postgres://db.internal:5432/rota_saude_platform_production",
      "ROTA_APP_PASSWORD" => "app-secret",
      "ROTA_ADMIN_PASSWORD" => "admin-secret",
      "ROTA_PLATFORM_PASSWORD" => "platform-secret"
    ).except("CITY_UNSET_DATABASE_URL"))

    raw = ActiveSupport::ConfigurationFile.parse(Rails.root.join("config/database.yml"))
    production = ActiveRecord::DatabaseConfigurations.new(raw)
      .configs_for(env_name: "production", include_hidden: true)
      .index_by(&:name)

    test_names = ActiveRecord::Base.configurations
      .configs_for(env_name: "test", include_hidden: true)
      .map(&:name)
    expect(test_names).not_to be_empty

    test_names.each do |name|
      config = production[name]
      expect(config).not_to be_nil, "production has no `#{name}` stanza"
      expect(config.adapter).to be_present, "production `#{name}` has no adapter"
      expect(config.database).to be_present, "production `#{name}` has no database"
    end
  end
end
