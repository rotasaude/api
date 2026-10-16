require "uri"

module FakeMiddleware
  # O simulado só roda em development e só fala com destino local (nunca com um api real).
  module Guard
    LOCAL_HOSTS = %w[localhost 127.0.0.1 ::1 api host.docker.internal].freeze

    module_function

    def environment_ok?(env) = env.to_s == "development"

    def local_url?(url)
      host = URI(url.to_s).host.to_s.delete_prefix("[").delete_suffix("]").downcase
      return false if host.empty?

      LOCAL_HOSTS.include?(host) || host.end_with?(".localhost") || host.end_with?(".test")
    rescue URI::InvalidURIError
      false
    end
  end
end
