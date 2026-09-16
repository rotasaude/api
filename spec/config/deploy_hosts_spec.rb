require "rails_helper"

# Plano 6: o proxy do Kamal precisa aceitar o console, o callback do gov.br e
# QUALQUER host de cidade — senão a cidade nova provisionada não atende, mesmo
# com a aplicação pronta para servi-la.
RSpec.describe "Kamal proxy hosts" do
  %w[development production].each do |env|
    it "publishes console, auth and a city wildcard in #{env}" do
      config = YAML.load_file(Rails.root.join("deploy/#{env}/deploy.yml"))
      hosts = config.fetch("proxy").fetch("hosts")

      expect(hosts.any? { |h| h.start_with?("admin.") }).to be(true), "sem host do console em #{env}"
      expect(hosts.any? { |h| h.start_with?("auth.") }).to be(true), "sem host do callback gov.br em #{env}"
      expect(hosts.any? { |h| h.start_with?("*.") }).to be(true), "sem curinga de cidade em #{env}"
      expect(config.fetch("proxy")).not_to have_key("host")
    end
  end
end
