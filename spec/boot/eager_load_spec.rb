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

  describe "production and staging stanzas of config/database.yml" do
    # database.yml's production/staging ERB uses ENV.fetch without defaults for
    # the passwords; provide them (and the URLs) only inside these examples.
    before do
      stub_const("ENV", ENV.to_h.merge(
        "PLATFORM_DATABASE_URL" => "postgres://db.internal:5432/rota_saude_platform_production",
        "ROTA_APP_PASSWORD" => "app-secret",
        "ROTA_PLATFORM_PASSWORD" => "platform-secret"
      ).except("CITY_UNSET_DATABASE_URL"))
    end

    # Resolved without connecting.
    def configs_for(env)
      raw = ActiveSupport::ConfigurationFile.parse(Rails.root.join("config/database.yml"))
      ActiveRecord::DatabaseConfigurations.new(raw).configs_for(env_name: env, include_hidden: true)
    end

    # Fix wave (Important #5): staging is a YAML alias of production
    # (`staging: *production`), so this loop cannot actually catch staging
    # drifting from production — it proves the stanza resolves under staging's
    # own env_name too, the same guarantee the guard gave production alone.
    %w[production staging].each do |env|
      # Catches a new connects_to target declared for test with no stanza under
      # this environment. Derived from the test configurations, not hardcoded.
      it "declares a #{env} connection for every test connection" do
        test_names = ActiveRecord::Base.configurations
          .configs_for(env_name: "test", include_hidden: true)
          .map(&:name)
        expect(test_names).not_to be_empty

        env_names = configs_for(env).map(&:name)
        test_names.each do |name|
          expect(env_names).to include(name), "#{env} has no `#{name}` stanza"
        end
      end

      # Covers every connection under this environment, including those with no
      # test stanza (cache: test uses :null_store, no `cache` config in
      # database.yml).
      it "resolves an adapter and a database for every #{env} connection" do
        configs = configs_for(env)
        expect(configs).not_to be_empty

        configs.each do |config|
          expect(config.adapter).to be_present, "#{env} `#{config.name}` has no adapter"
          expect(config.database).to be_present, "#{env} `#{config.name}` has no database"
        end
      end
    end
  end
end
