require "rails_helper"

# Card rotasaude/api#62: o token de /v e /r não pode ir ao log de requisição,
# nem por variações de caminho (barras repetidas, percent-encoding).
RSpec.describe RequestLogPathMask do
  def logged(path)
    # env_for leria "//v/x" como URL de rede (host "v"): monta o PATH_INFO à mão.
    info, query = path.split("?", 2)
    env = Rack::MockRequest.env_for("/").merge("PATH_INFO" => info, "QUERY_STRING" => query.to_s)
    request = ActionDispatch::Request.new(env)
    Rails::Rack::Logger.new(->(_env) { [ 200, {}, [] ] }).send(:started_request_message, request)
  end

  {
    "/v/abc123token" => "/v/[FILTERED]",
    "/v//abc123token" => "/v/[FILTERED]",
    "//v/abc123token" => "/v/[FILTERED]",
    "//v//abc123token//" => "/v/[FILTERED]/",
    "/v/abc123token/" => "/v/[FILTERED]/",
    "/v//abc123token//signed.pdf" => "/v/[FILTERED]/signed.pdf",
    "/%76/abc123token" => "/v/[FILTERED]",
    "/%56/abc123token" => "/V/[FILTERED]",
    "/%72/abc123token" => "/r/[FILTERED]",
    "/%52//abc123token" => "/R/[FILTERED]",
    "/v/%61bc123token" => "/v/[FILTERED]",
    "/v/abc%31%32%33token/signed.pdf" => "/v/[FILTERED]/signed.pdf",
    "/v%2Fabc123token" => "/v/[FILTERED]",
    "/r//abc123token?k=1" => "/r/[FILTERED]?k=1"
  }.each do |raw, expected|
    it "mascara #{raw}" do
      expect(described_class.mask(raw)).to eq(expected)
      message = logged(raw)
      expect(message).to include(%("#{expected}"))
      %w[abc123token %61bc abc%31].each { |leak| expect(message).not_to include(leak) }
    end
  end

  it "mantém /v/lookup legível, inclusive com barras extras e %76" do
    [ "/v/lookup", "//v//lookup", "/%76/lookup", "/v/lookup?x=1" ].each do |raw|
      expect(described_class.mask(raw)).to eq(raw)
    end
    expect(logged("//v//lookup")).to include('"//v//lookup"')
  end

  it "não toca em outros caminhos" do
    %w[/ /up /vx/abc /attendance//x].each { |raw| expect(described_class.mask(raw)).to eq(raw) }
  end
end
