# URLs do SI-BNAFAR (módulo 27b, Valor 10). Da PLATAFORMA, por ambiente, nas
# credenciais cifradas do Rails: bnafar.{homologation,production}.{auth_url,api_url}
# (manual §8). O simulado existe só fora de produção, com FAKE_BNAFAR_URL
# (`#{base}/jwtauth/auth` e `#{base}/bnafar`). Nenhuma URL em inspect, log ou
# erro. Não atribui Current.city.
module Bnafar
  module Config
    Settings = Data.define(:auth_url, :api_url, :simulated) do
      def inspect = "#<Bnafar::Config::Settings #{simulated ? 'simulated' : 'real'}>"
      alias_method :to_s, :inspect
      def pretty_print(pp) = pp.text(inspect)
      def as_json(*) = { "simulated" => simulated }
    end

    module_function

    def credentials = Rails.application.credentials.dig(:bnafar).to_h.deep_stringify_keys

    # O interruptor decide o alvo (simulado × real) pelo `enabled?`, não pelo
    # `usable?`: a credencial recusada derruba o `usable?`, e o teste da
    # credencial (que a reabilita) precisa seguir falando com o mesmo alvo.
    def for_city(city, environment:, env: Rails.env)
      return nil if city.nil? || city.id.nil?
      return nil unless Bnafar::Catalog::ENVIRONMENTS.include?(environment)

      Platform::Features.enabled?(city, Mock::KEY, env: env) ? simulated : real(environment, env: env)
    end

    def real(environment, env: Rails.env)
      raw = credentials[environment].to_h.stringify_keys
      auth = raw["auth_url"].to_s.chomp("/")
      api = raw["api_url"].to_s.chomp("/")
      return nil unless [ auth, api ].all? { |url| url_ok?(url, env) }

      Settings.new(auth_url: auth, api_url: api, simulated: false)
    end

    def simulated
      base = ENV["FAKE_BNAFAR_URL"].presence&.chomp("/")
      return nil unless base && url_ok?(base, "development")

      Settings.new(auth_url: "#{base}/jwtauth/auth", api_url: "#{base}/bnafar", simulated: true)
    end

    def url_ok?(url, env)
      uri = URI.parse(url)
      uri.host.present? && (uri.scheme == "https" || (%w[development test].include?(env.to_s) && uri.scheme == "http"))
    rescue URI::InvalidURIError
      false
    end
    private_class_method :url_ok?
  end
end
