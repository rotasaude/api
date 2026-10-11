# app/services/sncr/client.rb
# Cliente da API do SNCR (ADR 0034; Manual da API 3ª ed.; Desvios 1–3). O
# navegador faz o login (gov.br pela Anvisa) e volta com session_id; o api
# troca o session_id pelo token (GET /auth/token, cabeçalho Origin = host da
# cidade, prova da Task 0) e pede o bloco (POST
# numeracoes/receita-especial-retencao) na mesma requisição — o token de 30 s
# vive só nesta chamada. Nomes de caminho e de campo moram SÓ aqui e no
# FakeSncr::App. Toda chamada registra a checagem (Sncr::Checks). Nada de
# token, session_id, número ou inscrição em log, erro ou inspect.
require "net/http"

module Sncr
  class Client
    TIMEOUT = 8 # duas chamadas com folga dentro dos 30 s do token
    KINDS = { "rce" => "RCE", "ret" => "RET" }.freeze
    COUNCILS = %w[CRM CRMV CRO].freeze
    # Nao provado (Task 0 pulada): gate de go-live em docs/pesquisa/2026-10-10-sncr-token-no-servidor.md
    SEND_ORIGIN = true
    PATHS = { login: "/auth/login", token: "/auth/token", block: "/numeracoes/receita-especial-retencao" }.freeze
    LIMIT = /limite m[aá]ximo de receita/i
    EXHAUSTED = /esgot/i
    REGISTRATION = /Inscri[cç][aã]o fornecida|n[aã]o possui v[ií]nculo|Prescritor n[aã]o encontrado|Usu[aá]rio autenticado n[aã]o encontrado/i
    NETWORK_ERRORS = [ SocketError, IOError, EOFError, SystemCallError, Net::OpenTimeout, Net::ReadTimeout,
                       Net::WriteTimeout, Net::ProtocolError, OpenSSL::SSL::SSLError ].freeze

    class Error < StandardError; end
    class Unavailable < Error; end           # rede, 5xx, configuração da plataforma, resposta inválida
    class Expired < Error; end               # session_id ou token vencido/repetido
    class LimitReached < Error; end          # 3 pedidos no mês
    class Exhausted < Error; end             # faixa esgotada na UF
    class RegistrationMismatch < Error; end  # gov.br ≠ inscrição, ou prescritor sem cadastro no SNCR

    Token = Data.define(:access_token) do
      def inspect = "#<Sncr::Client::Token [FILTERED]>"
      alias_method :to_s, :inspect
      def pretty_print(pp) = pp.text(inspect)
    end

    Block = Data.define(:first, :last, :quantity) do
      def inspect = "#<Sncr::Client::Block quantity=#{quantity}>"
      alias_method :to_s, :inspect
      def pretty_print(pp) = pp.text(inspect)
    end

    def self.for(city = Current.city, env: Rails.env)
      settings = Config.for_city(city, env: env)
      raise Unavailable, "SNCR não configurado" unless settings

      new(settings)
    end

    attr_reader :settings

    def initialize(settings, timeout: TIMEOUT)
      @settings = settings
      @timeout = timeout
    end

    def simulated? = @settings.simulated
    def provider = simulated? ? "sncr_simulated" : "sncr"

    def login_url(client_url:, state:)
      "#{@settings.public_auth_url}#{PATHS[:login]}?#{URI.encode_www_form(client_url: client_url, state: state)}"
    end

    def exchange(session_id:, origin:)
      uri = URI("#{@settings.auth_url}#{PATHS[:token]}?#{URI.encode_www_form(session_id: session_id)}")
      request = Net::HTTP::Get.new(uri)
      request["Accept"] = "application/json"
      request["Origin"] = origin if SEND_ORIGIN
      response = perform(uri, request)
      code = response.code.to_i
      raise Unavailable, "sncr_token_#{code}" if code >= 500 || code == 403 # 403 = domínio: configuração da plataforma

      access = parse(response.body)["access_token"]
      raise Expired, "sncr_session" unless code == 200 && access.is_a?(String) && access.present?

      Token.new(access_token: access)
    end

    def request_block(token:, kind:, council:, registration:, uf:)
      raise ArgumentError, "tipo desconhecido" unless KINDS.key?(kind)

      uri = URI("#{@settings.base_url}#{PATHS[:block]}")
      request = Net::HTTP::Post.new(uri)
      request["Accept"] = "application/json"
      request["Content-Type"] = "application/json"
      request["Authorization"] = "Bearer #{token.access_token}"
      request.body = JSON.generate(conselho: council, tipo: KINDS.fetch(kind), documento: registration, uf: uf,
                                   cnpj: @settings.cnpj)
      response = perform(uri, request)
      interpret_block(response.code.to_i, response.body.to_s.dup.force_encoding("UTF-8").scrub)
    end

    def inspect = "#<Sncr::Client #{provider}>"

    private

    def interpret_block(code, text)
      case code
      when 200, 201 then block(parse(text))
      when 401 then raise Expired, "sncr_token"
      when 404 then raise(REGISTRATION.match?(text) ? RegistrationMismatch : Unavailable, "sncr_404")
      when 400
        raise LimitReached, "sncr_limit" if LIMIT.match?(text)
        raise Exhausted, "sncr_exhausted" if EXHAUSTED.match?(text)
        raise RegistrationMismatch, "sncr_unregistered" if REGISTRATION.match?(text)

        raise Unavailable, "sncr_400" # CNPJ, conselho, UF: dados da plataforma
      else
        raise Unavailable, "sncr_#{code}"
      end
    end

    def block(body)
      first, last, quantity = body.values_at("inicio", "fim", "quantidade")
      raise Unavailable, "sncr_invalid_block" unless Numbers.expand(first, last, quantity)

      Block.new(first: first, last: last, quantity: quantity)
    end

    def perform(uri, request)
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: @timeout,
                                                     read_timeout: @timeout, write_timeout: @timeout) { |http| http.request(request) }
      Checks.record!(@settings, ok: response.code.to_i < 500)
      response
    rescue *NETWORK_ERRORS => e
      Checks.record!(@settings, ok: false)
      raise Unavailable, "SNCR inalcançável (#{e.class.name})"
    end

    def parse(text)
      parsed = JSON.parse(text.to_s.presence || "{}")
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError
      {}
    end
  end
end
