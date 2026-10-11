# app/services/sncr/config.rb
# Credenciais do SNCR (ADR 0034; spec §3; Desvio 2). Da PLATAFORMA, por
# ambiente, nas credenciais cifradas do Rails:
#   sncr.{base_url, auth_url, maintainer_cnpj}
# base_url = .../api-sncr/api/v1 (numeracoes/*); auth_url = base do /auth
# (login e token; o host conferido na Task 0). O SNCR não tem client_id nem
# secret. O simulado existe só fora de produção, com FAKE_SNCR_URL (o que o
# api usa) e FAKE_SNCR_PUBLIC_URL (o que o navegador abre). Nenhuma URL ou
# CNPJ em inspect, log ou erro. Lê Current.city, nunca a atribui.
module Sncr
  module Config
    REQUIRED = %w[base_url auth_url maintainer_cnpj].freeze
    SIMULATED_CNPJ = "11222333000181".freeze

    Settings = Data.define(:base_url, :auth_url, :public_auth_url, :cnpj, :simulated) do
      def inspect = "#<Sncr::Config::Settings #{simulated ? 'simulated' : 'real'}>"
      alias_method :to_s, :inspect
      def pretty_print(pp) = pp.text(inspect)
      def target = simulated ? "simulated" : "real"
    end

    module_function

    def credentials = Rails.application.credentials.dig(:sncr).to_h.deep_stringify_keys

    def real(env: Rails.env)
      raw = credentials
      return nil unless REQUIRED.all? { |key| raw[key].present? }

      base, auth = raw.values_at("base_url", "auth_url").map { |url| url.to_s.chomp("/") }
      return nil unless [ base, auth ].all? { |url| url_ok?(url, env) }

      cnpj = Cnpj.normalize(raw["maintainer_cnpj"])
      return nil unless cnpj

      Settings.new(base_url: base, auth_url: auth, public_auth_url: auth, cnpj: cnpj, simulated: false)
    end

    def simulated(env: Rails.env)
      return nil unless Platform::Features.find(Mock::KEY, env: env)

      base = ENV["FAKE_SNCR_URL"].presence&.chomp("/")
      return nil unless base

      Settings.new(base_url: base, auth_url: base, public_auth_url: ENV["FAKE_SNCR_PUBLIC_URL"].presence&.chomp("/") || base,
                   cnpj: SIMULATED_CNPJ, simulated: true)
    end

    def for_city(city = Current.city, env: Rails.env) = Mock.on?(city, env: env) ? simulated(env: env) : real(env: env)
    def configured? = !real.nil?
    def simulated_available?(env: Rails.env) = !simulated(env: env).nil?

    def url_ok?(url, env)
      uri = URI.parse(url)
      uri.host.present? && (uri.scheme == "https" || (%w[development test].include?(env.to_s) && uri.scheme == "http"))
    rescue URI::InvalidURIError
      false
    end
    private_class_method :url_ok?
  end
end
