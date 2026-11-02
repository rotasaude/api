# URLs da RNDS (módulo 29, Desvio 14). Da PLATAFORMA, por ambiente, nas
# credenciais cifradas do Rails:
#   rnds.{auth_url, ehr_url}            homologação (EHR-AUTH e EHR-Services)
#   rnds.{auth_url, ehr_url_template}   produção, com %{uf} (minúscula) na URL do EHR
# O simulado existe só fora de produção, com FAKE_RNDS_URL (auth e ehr na
# mesma base, http, sem mTLS). Nenhuma URL em inspect, log ou erro. Lê a
# cidade que recebe, nunca atribui Current.city.
module Rnds
  module Config
    Settings = Data.define(:auth_url, :ehr_url, :simulated) do
      def inspect = "#<Rnds::Config::Settings #{simulated ? 'simulated' : 'real'}>"
      alias_method :to_s, :inspect
      def pretty_print(pp) = pp.text(inspect)
    end

    module_function

    def credentials = Rails.application.credentials.dig(:rnds).to_h.deep_stringify_keys

    # O interruptor decide o alvo (simulado × real) pelo `enabled?`, não pelo
    # `usable?`: a credencial recusada derruba o `usable?`, e o teste da
    # credencial (que a reabilita) precisa seguir falando com o mesmo alvo.
    def for_city(city, env: Rails.env)
      return nil if city.nil? || city.id.nil?

      Platform::Features.enabled?(city, Mock::KEY, env: env) ? simulated : real(city, env: env)
    end

    def real(city, env: Rails.env)
      raw = credentials
      auth = raw["auth_url"].to_s.chomp("/")
      ehr = raw["ehr_url"].presence || ehr_from_template(raw["ehr_url_template"], city)
      ehr = ehr.to_s.chomp("/")
      return nil unless [ auth, ehr ].all? { |url| url_ok?(url, env) }

      Settings.new(auth_url: auth, ehr_url: ehr, simulated: false)
    end

    def simulated
      base = ENV["FAKE_RNDS_URL"].presence&.chomp("/")
      return nil unless base && url_ok?(base, "development")

      Settings.new(auth_url: base, ehr_url: base, simulated: true)
    end

    def ehr_from_template(template, city)
      uf = city&.uf.to_s.downcase
      return nil if template.blank? || !uf.match?(/\A[a-z]{2}\z/)

      format(template, uf: uf)
    rescue KeyError, ArgumentError
      nil
    end

    def url_ok?(url, env)
      uri = URI.parse(url)
      uri.host.present? && (uri.scheme == "https" || (%w[development test].include?(env.to_s) && uri.scheme == "http"))
    rescue URI::InvalidURIError
      false
    end
    private_class_method :ehr_from_template, :url_ok?
  end
end
