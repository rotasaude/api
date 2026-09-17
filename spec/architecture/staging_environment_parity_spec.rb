require "rails_helper"

# Spec da API de manutenção §4: staging é ensaio de produção. Cada arquivo de
# config com stanza por ambiente declara staging IGUAL a production — uma stanza
# esquecida só apareceria no boot de staging (AdapterNotSpecified, cidade sem
# worker, recorrência que não roda), longe da suíte, que roda em test.
RSpec.describe "Staging environment parity" do
  def parsed(file)
    ActiveSupport::ConfigurationFile.parse(Rails.root.join("config/#{file}.yml"))
  end

  %w[database cache queue queue_platform recurring recurring_platform].each do |file|
    it "declares config/#{file}.yml staging exactly as production" do
      config = parsed(file)

      expect(config).to have_key("staging"), "config/#{file}.yml: sem stanza staging"
      expect(config["staging"]).to eq(config["production"])
    end
  end

  it "builds config/environments/staging.rb on top of production.rb" do
    code = Rails.root.join("config/environments/staging.rb").read

    expect(code).to match(/^require_relative "production"$/)
  end
end
