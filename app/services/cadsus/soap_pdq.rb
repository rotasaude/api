require "net/http"
require "erb"
require "securerandom"

# PDQv3 do CADSUS (spec PDQ v5 do DATASUS; pesquisa frente 2): SOAP 1.2,
# usuário e senha no cabeçalho WS-Security, consulta por CPF
# (2.16.840.1.113883.13.237); o CNS volta como id 2.16.840.1.113883.13.236. A
# credencial vem da cidade; o acesso é autorizado pelo DATASUS. O formato é
# conferido na homologação antes de ligar o interruptor em qualquer cidade.
# Nenhuma mensagem de erro carrega senha, URL ou corpo da resposta.
module Cadsus
  class SoapPdq
    HOMOLOGATION_URL = "https://servicoshm.saude.gov.br/cadsus/PDQSupplier".freeze
    PRODUCTION_URL = "https://servicos.saude.gov.br/cadsus/PDQSupplier".freeze
    CPF_ROOT = "2.16.840.1.113883.13.237".freeze
    CNS_ROOT = "2.16.840.1.113883.13.236".freeze
    # CPF válido de teste, usado só para o teste de conexão (achar ou não achar
    # prova que a credencial foi aceita).
    HEALTH_CHECK_CPF = "11144477735".freeze
    TIMEOUT = 10
    NETWORK_ERRORS = [ SocketError, IOError, EOFError, SystemCallError, Net::OpenTimeout, Net::ReadTimeout,
                       Net::WriteTimeout, Net::ProtocolError, OpenSSL::SSL::SSLError ].freeze
    SEX = { "F" => "female", "M" => "male" }.freeze

    def self.default_url = Rails.env.production? ? PRODUCTION_URL : HOMOLOGATION_URL

    def initialize(url:, username:, password:, timeout: TIMEOUT)
      @url = url
      @username = username
      @password = password
      @timeout = timeout
    end

    def health_check
      lookup(HEALTH_CHECK_CPF)
      :ok
    end

    def lookup(cpf)
      response = post(envelope(cpf))
      doc = Nokogiri::XML(response.body.to_s)
      fault = doc.at_xpath("//*[local-name()='Fault']")
      code = response.code.to_i
      raise Unauthorized, "o CADSUS recusou a credencial" if [ 401, 403 ].include?(code) || security_fault?(fault)
      raise Unavailable, "o CADSUS respondeu #{code}" if fault || code >= 300

      patient = doc.at_xpath("//*[local-name()='patient']")
      return nil unless patient

      cns = patient.at_xpath(".//*[local-name()='id'][@root='#{CNS_ROOT}']")&.[]("extension")
      birth = patient.at_xpath(".//*[local-name()='birthTime']")&.[]("value").to_s[0, 8]
      sex = patient.at_xpath(".//*[local-name()='administrativeGenderCode']")&.[]("code")
      Record.new(cns: cns.presence, birth_date: birth.match?(/\A\d{8}\z/) ? Date.strptime(birth, "%Y%m%d") : nil,
                 sex: SEX[sex])
    rescue Date::Error
      raise Unavailable, "resposta do CADSUS com data inválida"
    end

    def inspect = "#<Cadsus::SoapPdq #{@url}>"

    private

    def security_fault?(fault)
      fault && fault.text.match?(/auth|secur|credencia|senha|password/i)
    end

    def post(body)
      uri = parse_url
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/soap+xml; charset=utf-8"
      request.body = body
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                          open_timeout: @timeout, read_timeout: @timeout, write_timeout: @timeout) do |http|
        http.request(request)
      end
    rescue *NETWORK_ERRORS => e
      raise Unavailable, "CADSUS inalcançável (#{e.class.name})"
    end

    # A mensagem de URI::InvalidURIError carrega a URL; nunca a repasse.
    def parse_url
      uri = URI.parse(@url.to_s)
      raise URI::InvalidURIError unless uri.is_a?(URI::HTTP) && uri.host.present?

      uri
    rescue URI::InvalidURIError
      raise Unavailable, "endereço do CADSUS inválido"
    end

    def envelope(cpf)
      h = ->(value) { ERB::Util.html_escape(value.to_s) }
      now = Time.current.utc.strftime("%Y%m%d%H%M%S")
      <<~XML
        <soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope" xmlns:urn="urn:hl7-org:v3">
          <soap:Header>
            <wsse:Security xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd">
              <wsse:UsernameToken>
                <wsse:Username>#{h.call(@username)}</wsse:Username>
                <wsse:Password Type="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordText">#{h.call(@password)}</wsse:Password>
              </wsse:UsernameToken>
            </wsse:Security>
          </soap:Header>
          <soap:Body>
            <urn:PRPA_IN201305UV02 ITSVersion="XML_1.0">
              <urn:id root="2.16.840.1.113883.4.714" extension="#{SecureRandom.uuid}"/>
              <urn:creationTime value="#{now}"/>
              <urn:interactionId root="2.16.840.1.113883.1.6" extension="PRPA_IN201305UV02"/>
              <urn:processingCode code="P"/>
              <urn:processingModeCode code="T"/>
              <urn:acceptAckCode code="AL"/>
              <urn:receiver typeCode="RCV"><urn:device classCode="DEV" determinerCode="INSTANCE"><urn:id root="2.16.840.1.113883.3.72.6.5.100.85"/></urn:device></urn:receiver>
              <urn:sender typeCode="SND"><urn:device classCode="DEV" determinerCode="INSTANCE"><urn:id root="2.16.840.1.113883.3.72.6.2"/><urn:name>ROTASAUDE</urn:name></urn:device></urn:sender>
              <urn:controlActProcess classCode="CACT" moodCode="EVN">
                <urn:code code="PRPA_TE201305UV02" codeSystem="2.16.840.1.113883.1.6"/>
                <urn:queryByParameter>
                  <urn:queryId root="1.2.840.114350.1.13.28.1.18.5.999" extension="#{SecureRandom.uuid}"/>
                  <urn:statusCode code="new"/>
                  <urn:responseModalityCode code="R"/>
                  <urn:responsePriorityCode code="I"/>
                  <urn:parameterList>
                    <urn:livingSubjectId>
                      <urn:value root="#{CPF_ROOT}" extension="#{h.call(cpf)}"/>
                      <urn:semanticsText>LivingSubject.id</urn:semanticsText>
                    </urn:livingSubjectId>
                  </urn:parameterList>
                </urn:queryByParameter>
              </urn:controlActProcess>
            </urn:PRPA_IN201305UV02>
          </soap:Body>
        </soap:Envelope>
      XML
    end
  end
end
