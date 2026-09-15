require "rails_helper"

# Plano 5 (decisão do usuário): o banco compartilhado rota_saude_<env> não é mais
# usado. Fila: cidade e plataforma; cache: plataforma; ActiveRecord::Base: banco
# vazio que falha fechado.
RSpec.describe "Shared database retired" do
  def database_yml
    YAML.safe_load(ERB.new(Rails.root.join("config/database.yml").read).result, aliases: true)
  end

  it "declares no queue database and keeps primary on the empty database, outside database tasks" do
    %w[development test production].each do |env|
      expect(database_yml[env]).not_to have_key("queue"), "config/database.yml: queue under #{env}"
      expect(database_yml[env]["primary"]).to include("database" => "rota_saude_no_city_selected", "database_tasks" => false)
    end
  end

  it "puts Solid Cache on the platform database, outside database tasks" do
    %w[development production].each do |env|
      expect(database_yml[env]["cache"]).to include("username" => "rota_platform", "database_tasks" => false)
    end
    expect(database_yml["development"]["cache"]["database"]).to eq(database_yml["development"]["platform"]["database"])
    expect(ActiveSupport::ConfigurationFile.parse(Rails.root.join("config/cache.yml"))["production"]).to include("database" => "cache")
  end

  it "resolves ActiveRecord::Base to the empty database" do
    expect(ActiveRecord::Base.connection_db_config.database).to eq("rota_saude_no_city_selected")
  end

  it "leaves no schema dump or entry point of the shared database behind" do
    %w[db/schema.rb db/queue_schema.rb db/cache_schema.rb bin/jobs].each do |path|
      expect(Rails.root.join(path)).not_to exist
    end
  end

  # Fix round 1, Important: cache and platform share the same physical database
  # (config/cache.yml's `database: cache` config), but a blackholed platform DB
  # must not block Rails.cache (rate_limit, Protocols.current) for the ~2 min TCP
  # default — connect_timeout: 5 has to be on BOTH configs, not just platform.
  it "puts cache on the same database as platform, in both environments, with a short connect_timeout on each" do
    cache_yml = ActiveSupport::ConfigurationFile.parse(Rails.root.join("config/cache.yml"))

    %w[development production].each do |env|
      expect(cache_yml[env]).to include("database" => "cache"), "config/cache.yml: no database: cache under #{env}"

      cache_config = ActiveRecord::Base.configurations.configs_for(env_name: env, name: "cache", include_hidden: true)
      platform_config = ActiveRecord::Base.configurations.configs_for(env_name: env, name: "platform", include_hidden: true)

      expect(cache_config.database).to eq(platform_config.database)
      expect(cache_config.configuration_hash[:connect_timeout]).to eq(5), "config/database.yml: cache under #{env} has no connect_timeout"
      expect(platform_config.configuration_hash[:connect_timeout]).to eq(5), "config/database.yml: platform under #{env} has no connect_timeout"
    end
  end
end
