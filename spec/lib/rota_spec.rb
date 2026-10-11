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

  # Card api#62: os rate_limit contam por request.remote_ip; atrás do proxy de
  # borda das cidades o Rails só enxerga o IP real se souber quem é proxy.
  describe ".trusted_proxies" do
    let(:defaults) { ActionDispatch::RemoteIp::TRUSTED_PROXIES }

    def added(value) = described_class.trusted_proxies(value) - defaults

    it "separa por vírgula, espaço ou os dois, ignorando entradas vazias" do
      expect(added("198.51.100.0/24,203.0.113.10")).to eq([ IPAddr.new("198.51.100.0/24"), IPAddr.new("203.0.113.10") ])
      expect(added("198.51.100.0/24 203.0.113.10")).to eq(added("198.51.100.0/24,203.0.113.10"))
      expect(added(" 198.51.100.0/24 ,, 203.0.113.10\n")).to eq(added("198.51.100.0/24,203.0.113.10"))
    end

    it "aceita IPv6, CIDR e IP único" do
      expect(added("2001:db8::/32,2001:db8:1::5")).to eq([ IPAddr.new("2001:db8::/32"), IPAddr.new("2001:db8:1::5") ])
    end

    it "mantém os padrões do Rails (loopback e redes privadas)" do
      list = described_class.trusted_proxies("198.51.100.0/24")
      expect(list.first(defaults.size)).to eq(defaults.to_a)
      expect(list.any? { |p| p === IPAddr.new("10.1.2.3") }).to be(true)
      expect(list.any? { |p| p === IPAddr.new("198.51.100.7") }).to be(true)
      expect(list.any? { |p| p === IPAddr.new("192.0.2.99") }).to be(false)
    end

    it "devolve nil quando não configurado (nil ou só espaços)" do
      expect(described_class.trusted_proxies(nil)).to be_nil
      expect(described_class.trusted_proxies("  \n ")).to be_nil
      expect(described_class.trusted_proxies(" , ")).to be_nil
    end

    it "recusa entrada inválida nomeando a variável e a entrada" do
      [ "10.0.0.0/33", "banana", "1.2.3", "198.51.100.0/24,banana" ].each do |value|
        bad = value.split(",").last
        expect { described_class.trusted_proxies(value) }
          .to raise_error(Rota::InvalidTrustedProxies, /TRUSTED_PROXIES.*#{Regexp.escape(bad)}/)
      end
    end
  end

  describe ".trusted_proxies (confiar em tudo)" do
    it "recusa entrada de prefixo 0, que anularia o limite por IP, nomeando a variável e a entrada" do
      [ "0.0.0.0/0", "::/0", "::ffff:0:0/0", "10.1.2.3/0", "198.51.100.0/24,0.0.0.0/0", "::1/0" ].each do |value|
        bad = value.split(",").last
        expect { described_class.trusted_proxies(value) }
          .to raise_error(Rota::InvalidTrustedProxies, /TRUSTED_PROXIES.*#{Regexp.escape(bad)}.*limite por IP/m)
      end
    end

    it "continua aceitando CIDRs largos porém não totais" do
      expect { described_class.trusted_proxies("10.0.0.0/8,2001:db8::/32,0.0.0.0/1") }.not_to raise_error
    end
  end

  describe ".warn_missing_trusted_proxies" do
    let(:logger) { instance_double(Logger, warn: nil) }

    it "avisa, nomeando a variável e o efeito, em ambiente publicado sem a variável" do
      %w[production staging].each do |env|
        described_class.warn_missing_trusted_proxies(env: env, value: nil, logger: logger)
      end
      expect(logger).to have_received(:warn).twice.with(/TRUSTED_PROXIES.*IP do proxy/m)
      described_class.warn_missing_trusted_proxies(env: "production", value: "  ", logger: logger)
      expect(logger).to have_received(:warn).exactly(3).times
    end

    it "não avisa com a variável presente nem em development/test" do
      described_class.warn_missing_trusted_proxies(env: "production", value: "198.51.100.0/24", logger: logger)
      %w[development test].each { |env| described_class.warn_missing_trusted_proxies(env: env, value: nil, logger: logger) }
      expect(logger).not_to have_received(:warn)
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

    # Decisão do usuário (fechamento do módulo 06, F-06.12): produção também
    # não sobe lendo o arquivo compartilhado — antes, com o RAILS_MASTER_KEY
    # certo, as chaves de dev venciam as do cofre.
    it "refuses production reading the shared credentials file" do
      expect do
        described_class.check_credentials!(env: "production", content_path: Pathname("/rails/config/credentials.yml.enc"))
      end.to raise_error(Rota::SharedCredentials, %r{config/credentials/production\.yml\.enc})
    end

    it "accepts production reading its own credentials file" do
      expect do
        described_class.check_credentials!(env: "production",
                                           content_path: Pathname("/rails/config/credentials/production.yml.enc"))
      end.not_to raise_error
    end

    it "isolates every deployed environment" do
      expect(Rota::ISOLATED_CREDENTIALS_ENVS).to match_array(Rota::DEPLOYED_ENVS)
    end

    it "does not judge the environments outside the isolated list" do
      %w[development test].each do |env|
        expect do
          described_class.check_credentials!(env: env, content_path: Pathname("/rails/config/credentials.yml.enc"))
        end.not_to raise_error
      end
    end
  end
end
