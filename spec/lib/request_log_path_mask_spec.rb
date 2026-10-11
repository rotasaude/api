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

  def logged_raw(path)
    info, query = path.b.split("?", 2)
    env = Rack::MockRequest.env_for("/").merge("PATH_INFO" => info, "QUERY_STRING" => query.to_s)
    Rails::Rack::Logger.new(->(_env) { [ 200, {}, [] ] }).send(:started_request_message, ActionDispatch::Request.new(env))
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

  describe "bytes inválidos ou codificação mista" do
    [ "/v/é%FF", "/ação/%C3%A9", "/v/\xFF", "/v/\xC3(abc", "/x\xFF/y", "/v/abc123token\xFF", "/%76/\xC3\x28abc123token" ].each do |raw|
      it "nunca levanta com #{raw.inspect}" do
        expect { described_class.mask(raw) }.not_to raise_error
        expect { logged_raw(raw) }.not_to raise_error
      end
    end

    it "mascara o token mesmo com byte inválido ao redor" do
      %W[/v/abc123token\xFF /v/\xC3(abc123token /%76/abc123token%FF].each do |raw|
        expect(described_class.mask(raw)).not_to include("abc123token")
        expect(logged_raw(raw)).not_to include("abc123token")
      end
    end

    it "caminho ASCII sem token segue intacto" do
      expect(described_class.mask("/up")).to eq("/up")
      expect(described_class.mask("/x\xFF/y".b)).to eq("/x\xFF/y".b)
    end

    it "na falha inesperada devolve valor totalmente mascarado, nunca o original" do
      allow(described_class).to receive(:normalize).and_raise(RuntimeError)
      expect(described_class.mask("/v/abc123token")).to eq("/[FILTERED]")
    end
  end

  describe "RoutingError no log de exceções" do
    def composed(message)
      wrapper = instance_double(ActionDispatch::ExceptionWrapper, has_cause?: false, exception_class_name: "ActionController::RoutingError",
                                message: message, annotated_source_code: [], exception_trace: [])
      middleware = ActionDispatch::DebugExceptions.new(->(_e) { [ 200, {}, [] ] })
      middleware.send(:compose_exception_message, wrapper).join("\n")
    end

    it "mascara o caminho citado e preserva o resto da mensagem" do
      %w[/%76/abc123token /%72/abc123token /v/abc123token/signed.pdf].each do |raw|
        out = composed(%(No route matches [GET] #{raw.inspect}))
        expect(out).not_to include("abc123token")
        expect(out).to include("No route matches [GET]", "[FILTERED]")
      end
      expect(composed(%(No route matches [GET] "/nada"))).to include('"/nada"')
    end
  end
end
