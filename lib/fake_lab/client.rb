require "net/http"
require "uri"
require "json"

module FakeLab
  # Fala com o api pelo endereço interno (FAKE_LAB_API_URL) e diz a cidade
  # pelo Host (FAKE_LAB_CITY_HOST) — o api resolve a cidade pelo host.
  class Client
    MEDIA_TYPE = "application/fhir+json".freeze

    def initialize(api_url:, city_host:, token:)
      @uri = URI(api_url)
      @city_host = city_host
      @token = token
    end

    def service_requests
      response = request(Net::HTTP::Get.new("/fhir/ServiceRequest?status=active"))
      return [] unless response.code == "200"

      JSON.parse(response.body).fetch("entry", []).map { |entry| entry["resource"] }
    end

    def last_status = @last_status

    def send_report(report)
      req = Net::HTTP::Post.new("/fhir/DiagnosticReport")
      req["Content-Type"] = MEDIA_TYPE
      req.body = JSON.generate(report)
      request(req).code.to_i
    end

    private

    def request(req)
      req["Host"] = @city_host
      req["Authorization"] = "Bearer #{@token}"
      req["Accept"] = MEDIA_TYPE
      Net::HTTP.start(@uri.host, @uri.port, use_ssl: @uri.scheme == "https", open_timeout: 5, read_timeout: 30) do |http|
        http.request(req).tap { |response| @last_status = response.code.to_i }
      end
    end
  end
end
