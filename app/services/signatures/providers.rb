# PSC de nuvem da ICP-Brasil (ADR 0032; spec §3). Credenciais da PLATAFORMA,
# por ambiente, nas credenciais cifradas do Rails:
#   signature.providers.<key>.{client_id, client_secret, base_url[, authorize_base_url]}
# Sem as três chaves o PSC não está habilitado. Nenhum segredo em inspect, log
# ou erro.
#
# ADR 0032 (revisão): o PSC simulado (`simulated`) NÃO está no catálogo nem
# nas credenciais. Existe só fora de produção, com FAKE_PSC_URL (endereço que
# o api/worker usa) e FAKE_PSC_PUBLIC_URL (o que o navegador abre). A cidade
# com o interruptor signature_psc_mock LIGADO usa só ele; DESLIGADO, só os
# reais configurados no ambiente. Lê Current.city, nunca a atribui.
module Signatures
  module Providers
    CATALOG = SignerCertificate::REAL_PROVIDERS
    SIMULATED = "simulated".freeze
    LABELS = { "vidaas" => "VIDaaS", "birdid" => "BirdID", "safeid" => "SafeID", "neoid" => "NeoID",
               "remoteid" => "RemoteID", SIMULATED => "PSC simulado" }.freeze
    REQUIRED = %w[client_id client_secret base_url].freeze
    # Iguais a FakePsc::App::CLIENT_ID/CLIENT_SECRET (spec fixa a igualdade; o
    # app não carrega lib/fake_psc). Não são segredo: só valem no falso.
    SIMULATED_CLIENT_ID = "rota-dev".freeze
    SIMULATED_CLIENT_SECRET = "dev-secret".freeze

    Provider = Data.define(:key, :client_id, :client_secret, :base_url, :authorize_base_url) do
      def inspect = "#<Signatures::Providers::Provider #{key}>"
      alias_method :to_s, :inspect
    end

    module_function

    # Só os PSC reais, das credenciais cifradas do ambiente.
    def credentials = Rails.application.credentials.dig(:signature, :providers).to_h.deep_stringify_keys

    # Os PSC que a cidade usa (interruptor signature_psc_mock).
    def for_city(city = Current.city, env: Rails.env)
      PscMock.on?(city, env: env) ? [ simulated(env: env) ].compact : configured_in_environment
    end

    def find(key, city: Current.city, env: Rails.env) = for_city(city, env: env).find { |provider| provider.key == key.to_s }
    def configured(city: Current.city) = for_city(city)
    def configured?(key, city: Current.city) = !find(key, city: city).nil?

    # Reais configurados no ambiente, sem olhar cidade (maintenance §8).
    def configured_in_environment = CATALOG.filter_map { |key| real(key) }
    def configured_in_environment?(key) = !real(key).nil?

    # nil em produção (o interruptor nem existe lá) ou sem FAKE_PSC_URL.
    def simulated(env: Rails.env)
      return nil unless Platform::Features.find(PscMock::KEY, env: env)

      base_url = ENV["FAKE_PSC_URL"].presence
      return nil unless base_url

      Provider.new(key: SIMULATED, client_id: SIMULATED_CLIENT_ID, client_secret: SIMULATED_CLIENT_SECRET,
                   base_url: base_url.chomp("/"), authorize_base_url: ENV["FAKE_PSC_PUBLIC_URL"].presence&.chomp("/"))
    end

    # Desvio 9: um retorno por cidade, montado do host público do dashboard dela
    # (https://<host da cidade>/dashboard/signature/callback). Cada endereço é
    # cadastrado em cada PSC no go-live da cidade (Task 19).
    def redirect_uri(city) = "#{CityPublicUrl.dashboard(city)}signature/callback"

    def record_check!(key, ok:) = SignatureProviderCheck.record!(key, ok: ok)
    def checks = SignatureProviderCheck.where(provider: CATALOG).index_by(&:provider)

    def real(key)
      key = key.to_s
      return nil unless CATALOG.include?(key)

      raw = credentials[key]
      return nil unless raw.is_a?(Hash) && REQUIRED.all? { |name| raw[name].present? }

      Provider.new(key: key, client_id: raw["client_id"].to_s, client_secret: raw["client_secret"].to_s,
                   base_url: raw["base_url"].to_s.chomp("/"), authorize_base_url: raw["authorize_base_url"].presence&.chomp("/"))
    end
    private_class_method :real
  end
end
