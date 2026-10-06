# spec/support/ledi_helpers.rb
# Exportador LEDI (módulo 16): deixa uma cidade pronta para exportar com os
# nomes da fundação (interruptor, modo, endereço do PEC, IBGE, credencial) e
# troca o PEC por um falso que registra o que recebeu. Se a fundação mudar um
# nome, o ajuste é AQUI (Task 2, Step 1).
class FakePec
  attr_reader :base_url, :logins, :deliveries
  attr_accessor :login_replies, :delivery_replies

  def self.registry = (@registry ||= {})
  def self.for(base_url) = registry[base_url] ||= new(base_url)
  def self.reset! = registry.clear

  def initialize(base_url)
    @base_url = base_url
    @logins = []
    @deliveries = []
    @login_replies = []
    @delivery_replies = []
  end

  # O stub de Ledi::PecClient.new devolve este objeto com as credenciais do
  # cliente construído (o falso é um por endereço; a credencial é a da vez).
  def with_credentials(username, password)
    @username, @password = username, password
    self
  end

  # login_replies: :ok (padrão) ou uma classe de erro do Ledi::PecClient.
  def login
    @logins << { username: @username, password: @password }
    reply = @login_replies.shift || :ok
    raise reply, "fake" unless reply == :ok

    Ledi::PecClient::Session.new(cookie: "JSESSIONID=fake-#{@logins.size}")
  end

  # delivery_replies: [status, corpo] (padrão [201, ""]) ou uma classe de erro.
  def deliver(cookie:, filename:, bytes:)
    @deliveries << { cookie: cookie, filename: filename, bytes: bytes }
    reply = @delivery_replies.shift || [ 201, "" ]
    raise reply, "fake" if reply.is_a?(Class)

    Ledi::PecClient::Reply.new(status: reply[0], body: reply[1])
  end
end

module LediHelpers
  def stub_pec!
    allow(Ledi::PecClient).to receive(:new) do |base_url:, username:, password:, **|
      FakePec.for(base_url).with_credentials(username, password)
    end
  end

  def ledi_maintainer!
    Maintainer.find_by(email_address: "ledi-mantenedor@rotasaude.app") ||
      Maintainer.create!(email_address: "ledi-mantenedor@rotasaude.app", password: "s3nha-forte-1",
                         otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
  end

  def ledi_admin!
    User.find_by(email_address: "ledi-admin@cidade.gov.br") || staff_with("ledi-admin@cidade.gov.br", "municipal_admin")
  end

  # Liga ledi_export para `city` (City da plataforma) e prepara o banco DELA.
  def ledi_ready!(city, pec_url:, username: "rota", password: "segredo-ledi", record_mode: "integrated",
                  ibge_code: "4115200")
    city.update!(record_mode: record_mode, pec_url: pec_url)
    Platform::Features.set!(city: city, key: "ledi_export", enabled: true, maintainer: ledi_maintainer!)
    CityConnection.with(city) do
      profile = CityProfile.current || CityProfile.create!(name: city.name)
      profile.update!(ibge_code: ibge_code)
      credential = IntegrationCredential.find_or_initialize_by(kind: "ledi")
      credential.update!(secret: { "username" => username, "password" => password }, set_by_user: ledi_admin!,
                         set_at: Time.current, last_check_status: "ok", last_check_at: Time.current)
    end
    city
  end

  def ledi_off!(city)
    Platform::Features.set!(city: city, key: "ledi_export", enabled: false, maintainer: ledi_maintainer!)
  end
end

RSpec.configure do |config|
  config.include LediHelpers
  config.before do
    FakePec.reset!
    Ledi::SessionCache.clear! if defined?(Ledi::SessionCache)
  end
end
