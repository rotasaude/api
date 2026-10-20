require "rails_helper"
require "aws-sdk-s3"

RSpec.describe "City identity", type: :request do
  include CoatOfArmsHelpers

  let(:base) { "rotasaude.app" }
  let(:city_a_url) { ENV.fetch("TEST_CITY_A_URL", city_database_url(TEST_CITY_A_DATABASE)) }
  let!(:city) { create(:city, slug: "identidade", status: "active", database_url: city_a_url) }

  before do
    CityCatalog.reset_cache!
    host! "identidade.#{base}"
  end

  after { CityCatalog.reset_cache! }

  def attach(bytes)
    UpdateCityIdentity.call(city: City.find(city.id), coat_of_arms: coat_upload(bytes))
    CityCatalog.reset_cache!
  end

  it "devolve exatamente as cinco chaves, com cache de 300 s" do
    get "/city_identity"
    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body).keys).to match_array(%w[name uf time_zone health_department_name coat_of_arms_url])
    # Rails serializa as diretivas em ordem canônica ("max-age=300, public").
    expect(response.headers["Cache-Control"].split(", ")).to match_array(%w[public max-age=300])
  end

  it "sem brasão e sem órgão: os dois null" do
    get "/city_identity"
    body = JSON.parse(response.body)
    expect(body["coat_of_arms_url"]).to be_nil
    expect(body["health_department_name"]).to be_nil
  end

  it "com brasão e órgão, devolve a URL com o checksum do blob" do
    UpdateCityIdentity.call(city: City.find(city.id), health_department_name: "Secretaria de Saúde",
                            coat_of_arms: coat_upload(coat_png(512, 512)))
    CityCatalog.reset_cache!
    get "/city_identity"
    body = JSON.parse(response.body)
    expect(body["health_department_name"]).to eq("Secretaria de Saúde")
    expect(body["coat_of_arms_url"]).to eq("/city_identity/coat_of_arms?v=#{CGI.escape(City.find(city.id).coat_of_arms.blob.checksum)}")
  end

  it "checksum com +, / e =: a URL vai escapada e, seguida como está, devolve a imagem" do
    bytes = coat_png(512, 512)
    attach(bytes)
    allow_any_instance_of(ActiveStorage::Blob).to receive(:checksum).and_return("ab+cd/ef0=")
    get "/city_identity"
    url = JSON.parse(response.body)["coat_of_arms_url"]
    expect(url).to eq("/city_identity/coat_of_arms?v=ab%2Bcd%2Fef0%3D")
    get url
    expect(response).to have_http_status(:ok)
    expect(response.body.b).to eq(bytes.b)
  end

  it "suspended, archived e provisioning dão 404 unknown_city (não 403)" do
    %w[suspended archived provisioning].each do |st|
      create(:city, slug: "c-#{st}", status: st, database_url: city_a_url)
      host! "c-#{st}.#{base}"
      get "/city_identity"
      expect([ response.status, JSON.parse(response.body) ]).to eq([ 404, { "error" => "unknown_city" } ])
    end
  end

  it "host desconhecido e host reservado (admin.*) dão 404" do
    %w[inexistente admin].each do |label|
      host! "#{label}.#{base}"
      get "/city_identity"
      expect(response).to have_http_status(:not_found)
    end
  end

  it "responde mesmo com o banco da cidade inalcançável e com schema atrasado" do
    city.update!(database_url: "postgres://inert:inert@127.0.0.1:1/inert", schema_version: nil)
    CityCatalog.reset_cache!
    get "/city_identity"
    expect(response).to have_http_status(:ok)
  end

  describe "imagem" do
    it "vem com content_type do blob, cache imutável e nosniff" do
      attach(coat_png(512, 512))
      get "/city_identity/coat_of_arms"
      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("image/png")
      expect(response.headers["Cache-Control"]).to include("immutable")
      expect(response.headers["Cache-Control"]).to include("max-age=31536000")
      expect(response.headers["X-Content-Type-Options"]).to eq("nosniff")
      expect(response.body.b).to eq(coat_png(512, 512))
    end

    it "v= igual ao checksum atual é servido; v= velho ou arbitrário dá 404 sem cache imutável" do
      attach(coat_png(512, 512))
      checksum = City.find(city.id).coat_of_arms.blob.checksum
      get "/city_identity/coat_of_arms", params: { v: checksum }
      expect(response).to have_http_status(:ok)

      get "/city_identity/coat_of_arms", params: { v: "velho" }
      expect(response).to have_http_status(:not_found)
      expect(response.headers["Cache-Control"].to_s).not_to include("immutable")
    end

    it "arquivo sumido do storage: 404" do
      attach(coat_png(512, 512))
      allow_any_instance_of(ActiveStorage::Blob).to receive(:download).and_raise(ActiveStorage::FileNotFoundError)
      get "/city_identity/coat_of_arms"
      expect(response).to have_http_status(:not_found)
    end

    [Aws::S3::Errors::ServiceUnavailable.new(nil, "x"), Seahorse::Client::NetworkingError.new(StandardError.new("x")),
     Errno::ECONNREFUSED.new].each do |error|
      it "storage fora do ar (#{error.class}): 503 com no-store" do
        attach(coat_png(512, 512))
        allow_any_instance_of(ActiveStorage::Blob).to receive(:download).and_raise(error)
        get "/city_identity/coat_of_arms"
        expect(response).to have_http_status(:service_unavailable)
        expect(response.headers["Cache-Control"]).to include("no-store")
      end
    end

    it "dá 404 sem brasão e para cidade não ativa" do
      get "/city_identity/coat_of_arms"
      expect(response).to have_http_status(:not_found)

      attach(coat_png(512, 512))
      city.update!(status: "suspended")
      CityCatalog.reset_cache!
      get "/city_identity/coat_of_arms"
      expect(response).to have_http_status(:not_found)
    end
  end

  it "trocar o brasão muda o v= da URL logo em seguida, sem esperar o cache do catálogo" do
    attach(coat_png(512, 512))
    get "/city_identity"
    url_before = JSON.parse(response.body)["coat_of_arms_url"]

    # sem reset_cache!: o catálogo ainda guarda o City antigo
    UpdateCityIdentity.call(city: City.find(city.id), coat_of_arms: coat_upload(coat_png(256, 256)))
    get "/city_identity"
    url_after = JSON.parse(response.body)["coat_of_arms_url"]

    expect(url_after).to be_present
    expect(url_after).not_to eq(url_before)
  end

  it "121ª chamada do JSON no minuto dá 429; a imagem não conta" do
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    attach(coat_png(512, 512))
    120.times { get "/city_identity" }
    expect(response).to have_http_status(:ok)
    get "/city_identity"
    expect(response).to have_http_status(:too_many_requests)
    expect(JSON.parse(response.body)).to eq("error" => "too_many_requests")
    get "/city_identity/coat_of_arms"
    expect(response).to have_http_status(:ok)
  end
end
