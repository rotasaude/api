require "rails_helper"

# Boot guard (Ruling R33). Two PRODUCTION boot blockers passed without any test
# because nothing in the project eager loads (development: eager_load = false;
# test: eager_load = ENV["CI"].present?):
#   - PlatformRecord.connects_to :platform with no `platform` stanza in production;
#   - config/storage.yml missing -> ActiveStorage raises during eager load.
#
# `Rails.application.eager_load!` is a no-op since Rails 7 (Rails::Engine#eager_load!
# is kept only for backwards compatibility), so this spec replays what the
# `eager_load!` initializer in Rails::Application::Finisher does when
# config.eager_load is true — regardless of ENV["CI"].
RSpec.describe "Boot guard" do
  it "eager loads the application like production does, without raising" do
    app = Rails.application

    expect {
      ActiveSupport.run_load_hooks(:before_eager_load, app)
      Zeitwerk::Loader.eager_load_all
      Rails.eager_load!
      app.config.eager_load_namespaces.each(&:eager_load!)
    }.not_to raise_error
  end

  describe "production stanzas of config/database.yml" do
    # Every connection the app declares in production: ApplicationRecord's
    # primary, PlatformRecord (:platform), CityRecord's bootstrap shard
    # (:city_unset), Solid Queue (:queue) and Solid Cache (:cache).
    EXPECTED = %w[primary platform city_unset queue cache].freeze

    # database.yml's production ERB uses ENV.fetch without defaults for the
    # passwords; provide them (and the URLs) only inside this example.
    let(:production_env) do
      ENV.to_h.merge(
        "DATABASE_URL" => "postgres://db.internal:5432/rota_saude_production",
        "PLATFORM_DATABASE_URL" => "postgres://db.internal:5432/rota_saude_platform_production",
        "ROTA_APP_PASSWORD" => "app-secret",
        "ROTA_ADMIN_PASSWORD" => "admin-secret",
        "ROTA_PLATFORM_PASSWORD" => "platform-secret"
      ).except("CITY_UNSET_DATABASE_URL")
    end

    let(:production_configs) do
      stub_const("ENV", production_env)
      raw = ActiveSupport::ConfigurationFile.parse(Rails.root.join("config/database.yml"))
      ActiveRecord::DatabaseConfigurations.new(raw)
        .configs_for(env_name: "production", include_hidden: true)
    end

    it "declares every expected connection" do
      expect(production_configs.map(&:name)).to include(*EXPECTED)
    end

    it "resolves an adapter and a database for each one, without connecting" do
      production_configs.each do |config|
        expect(config.adapter).to be_present, "production `#{config.name}` has no adapter"
        expect(config.database).to be_present, "production `#{config.name}` has no database"
      end
    end
  end
end
