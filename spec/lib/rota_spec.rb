require "rails_helper"

# Spec da API de manutenção §4: staging é ensaio de produção. "Ambiente
# publicado" é uma pergunta só — Rota.deployed? — e staging precisa de
# credentials próprias, sem cair em silêncio no arquivo compartilhado.
RSpec.describe Rota do
  describe ".deployed?" do
    it "is true only for the environments that run on shared infrastructure" do
      expect(described_class.deployed?("production")).to be(true)
      expect(described_class.deployed?("staging")).to be(true)
      expect(described_class.deployed?("development")).to be(false)
      expect(described_class.deployed?("test")).to be(false)
    end

    it "accepts the Rails environment inquirer and defaults to the current environment" do
      expect(described_class.deployed?(ActiveSupport::EnvironmentInquirer.new("staging"))).to be(true)
      expect(described_class.deployed?(:production)).to be(true)
      expect(described_class.deployed?).to be(false)
    end
  end

  describe ".check_credentials!" do
    it "refuses staging reading the shared credentials file" do
      expect do
        described_class.check_credentials!(env: "staging", content_path: Pathname("/rails/config/credentials.yml.enc"))
      end.to raise_error(Rota::SharedCredentials, %r{config/credentials/staging\.yml\.enc})
    end

    it "accepts staging reading its own credentials file" do
      expect do
        described_class.check_credentials!(env: "staging", content_path: Pathname("/rails/config/credentials/staging.yml.enc"))
      end.not_to raise_error
    end

    it "refuses staging reading another environment's own file" do
      expect do
        described_class.check_credentials!(env: "staging", content_path: "/rails/config/credentials/production.yml.enc")
      end.to raise_error(Rota::SharedCredentials)
    end

    it "does not judge the environments outside the isolated list" do
      %w[development test production].each do |env|
        expect do
          described_class.check_credentials!(env: env, content_path: Pathname("/rails/config/credentials.yml.enc"))
        end.not_to raise_error
      end
    end
  end
end
