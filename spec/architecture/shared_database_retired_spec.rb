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
end
