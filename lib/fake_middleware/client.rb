require "net/http"
require "uri"
require "json"

module FakeMiddleware
  # Fala com o api pelo endereço interno e diz a cidade pelo Host (como o fake-lab).
  class Client
    def initialize(api_url:, city_host:, token:)
      @uri = URI(api_url)
      @city_host = city_host
      @token = token
    end

    attr_reader :last_status

    def pending_barcodes
      response = request(Net::HTTP::Get.new("/lab/hl7/pending_barcodes"))
      response.code == "200" ? JSON.parse(response.body).fetch("barcodes", []) : []
    end

    def post(body)
      req = Net::HTTP::Post.new("/hl7/v2")
      req["Content-Type"] = "application/hl7-v2"
      req.body = body
      response = request(req)
      [ response.code.to_i, response.body.to_s ]
    end

    private

    def request(req)
      req["Host"] = @city_host
      req["Authorization"] = "Bearer #{@token}"
      Net::HTTP.start(@uri.host, @uri.port, use_ssl: @uri.scheme == "https", open_timeout: 5, read_timeout: 30) do |http|
        http.request(req).tap { |response| @last_status = response.code.to_i }
      end
    end
  end
end
