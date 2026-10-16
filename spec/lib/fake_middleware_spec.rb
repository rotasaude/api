require "rails_helper"
require Rails.root.join("lib/fake_middleware/runner").to_s
require Rails.root.join("lib/fake_middleware/guard").to_s

# Contrato §12: um ciclo lista pendentes, consulta a lista de trabalho e envia
# resultados de exemplo com um crítico (glicose 450) e uma repetição (glicose 98).
RSpec.describe FakeMiddleware::Runner, type: :request do
  before { lab_city!(fake_middleware: true) }

  let(:provider) { lab_provider! }
  let(:req) { received_requisition!(provider: provider, exams: [ lab_exam!(provider: provider) ]) }
  let(:token) { middleware_token!(provider, simulated: true) }
  let(:log_io) { StringIO.new }
  let(:logger) { Logger.new(log_io) }

  # O cliente fala com o próprio app de teste (sem rede).
  let(:client) do
    session = ActionDispatch::Integration::Session.new(Rails.application)
    session.host! test_city_host
    Class.new do
      define_method(:initialize) { |s, t| @s = s; @t = t; @bodies = [] }
      attr_reader :last_status, :bodies

      define_method(:pending_barcodes) do
        @s.get "/lab/hl7/pending_barcodes", headers: { "Authorization" => "Bearer #{@t}" }
        @last_status = @s.response.status
        @last_status == 200 ? JSON.parse(@s.response.body)["barcodes"] : []
      end

      define_method(:post) do |body|
        @bodies << body
        @s.post "/hl7/v2", params: body, headers: { "CONTENT_TYPE" => "application/hl7-v2", "Authorization" => "Bearer #{@t}" }
        @last_status = @s.response.status
        [ @last_status, @s.response.body ]
      end
    end.new(session, token)
  end

  it "envia o resultado, o crítico e a repetição; nada liberado" do
    req
    outcome = described_class.tick(client: client, logger: logger)
    expect(outcome).to eq([ [ req.samples.first.barcode, "GLI", "AA" ], [ req.samples.first.barcode, "GLI", "AA" ] ])
    rows = req.items.first.results.reload
    expect(rows.map(&:value)).to eq(%w[450 98])
    expect(rows.first.flag).to eq("critical_high")
    expect(ExamResult.count).to eq(0)
    expect(described_class.tick(client: client, logger: logger)).to eq([])
  end

  it "manda SPM-4 (material_key^rótulo^99RSL) como um middleware real" do
    sample = req.samples.first
    described_class.tick(client: client, logger: logger)
    oul = client.bodies.select { |b| b.include?("OUL^R22") }
    expect(oul.size).to eq(2)
    spm = oul.first.split("\r").find { |s| s.start_with?("SPM|") }.split("|")
    expect(spm[2]).to eq(sample.barcode)
    expect(spm[4]).to eq("#{Lab::Hl7::Builder.material_key(sample.material)}^#{sample.material}^99RSL")
  end

  it "loga só contagens, ids de controle e códigos MSA: nunca etiqueta, valor ou token" do
    sample = req.samples.first
    described_class.tick(client: client, logger: logger)
    log = log_io.string
    expect(log).to match(/MSA AA/)
    expect(log).to match(/MSH-10 M[0-9a-f]+/)
    [ sample.barcode, "450", "98", token, "glicose", "Bearer" ].each { |secret| expect(log).not_to include(secret) }
  end

  it "com fake_middleware desligado, só registra no log" do
    req
    Platform::Features.set!(city: City.find(Current.city.id), key: "fake_middleware", enabled: false, maintainer: ledi_maintainer!)
    expect(described_class.tick(client: client, logger: logger)).to eq([])
    expect(LabResult.count).to eq(0)
  end
end

RSpec.describe FakeMiddleware::Guard do
  it "aceita só destinos locais e o serviço api do compose" do
    %w[http://api:3000 http://localhost:3042 http://127.0.0.1:3000 http://[::1]:3000 http://curitiba.localhost:3000 http://host.docker.internal:3000].each do |url|
      expect(described_class.local_url?(url)).to be(true), url
    end
    %w[https://api.rotasaude.example http://10.0.0.5:3000 http://localhost.evil.com http://evil.com/localhost not-a-url].each do |url|
      expect(described_class.local_url?(url)).to be(false), url
    end
  end

  it "só roda em development" do
    expect(described_class.environment_ok?("development")).to be(true)
    %w[test staging production].each { |env| expect(described_class.environment_ok?(env)).to be(false) }
  end
end
