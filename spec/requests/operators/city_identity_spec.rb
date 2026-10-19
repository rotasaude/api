require "rails_helper"

# Identidade pública da cidade (nome do órgão e brasão), pelo operador no
# console. Brasão em Active Storage na plataforma, sem job: o blob nasce
# analisado e a remoção é purge síncrono (os jobs do Active Storage não passam
# pelo PlatformQueue.check!).
RSpec.describe "Console: identidade da cidade", type: :request do
  include CoatOfArmsHelpers

  let(:password) { "s3nha-forte-1" }
  let!(:operator) do
    Operator.create!(email_address: "op-#{SecureRandom.hex(3)}@rotasaude.app", password: password,
                     otp_secret: ROTP::Base32.random, otp_enabled: true)
  end
  let!(:city) { City.find_by!(slug: TEST_CITY_A.slug) }

  def json = JSON.parse(response.body)
  def patch_identity(body = {}, id: city.id, **rest) = patch("/cities/#{id}/identity", params: body.merge(rest))
  def audits = PlatformEvent.where(name: "city.identity_updated")
  def enqueued = ActiveJob::Base.queue_adapter.enqueued_jobs

  before do
    host! "admin.rotasaude.app"
    post "/session", params: { email_address: operator.email_address, password: password }
    post "/session/challenge", params: { session_id: json["session_id"], code: ROTP::TOTP.new(operator.otp_secret).now }
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
  end

  it "grava nome do órgão e brasão, audita sem bytes" do
    patch_identity(health_department_name: "Secretaria Municipal da Saúde", coat_of_arms: coat_upload(coat_png(512, 512)))

    expect(response).to have_http_status(:ok)
    expect(json["city"]["health_department_name"]).to eq("Secretaria Municipal da Saúde")
    expect(json["city"]["coat_of_arms_url"]).to eq("/city_identity/coat_of_arms?v=#{city.reload.coat_of_arms.blob.checksum}")
    ev = audits.sole
    expect(ev.payload).to include("city_id" => city.id, "fields" => %w[coat_of_arms health_department_name])
    expect(ev.payload.to_s.bytesize).to be < 300
  end

  it "o blob guardado tem o byte_size verificado e o tipo vindo dos bytes" do
    bytes = coat_png(300, 200, pad_to: 1000)
    patch_identity(coat_of_arms: coat_upload(bytes, type: "image/jpeg", name: "x.jpg"))

    blob = city.reload.coat_of_arms.blob
    expect(blob.byte_size).to eq(1000)
    expect(blob.download.b).to eq(bytes)
    expect(blob.content_type).to eq("image/png")
    expect(blob.filename.to_s).to eq("coat_of_arms.png")
    expect(blob.metadata).to include("analyzed" => true, "width" => 300, "height" => 200)
  end

  it "anexar não enfileira job nenhum (nem AnalyzeJob)" do
    patch_identity(coat_of_arms: coat_upload(coat_png(512, 512)))
    expect(response).to have_http_status(:ok)
    expect(enqueued).to be_empty
  end

  it "trocar o brasão apaga o blob antigo na hora, sem job" do
    patch_identity(coat_of_arms: coat_upload(coat_png(512, 512)))
    old_key = city.reload.coat_of_arms.blob.key
    expect { patch_identity(coat_of_arms: coat_upload(coat_png(256, 256))) }.not_to change(ActiveStorage::Blob, :count)
    expect(city.reload.coat_of_arms.blob.key).not_to eq(old_key)
    expect(enqueued).to be_empty
  end

  it "\"\" limpa o nome do órgão; nada mudou não audita" do
    patch_identity(health_department_name: "Secretaria X")
    patch_identity(health_department_name: "")
    expect(json["city"]["health_department_name"]).to be_nil
    expect { patch_identity({}) }.not_to change(audits, :count)
    expect { patch_identity(health_department_name: "") }.not_to change(audits, :count)
  end

  it "121 caracteres dá 422 invalid_health_department_name e não grava nada (nem o brasão enviado junto)" do
    expect { patch_identity(health_department_name: "a" * 121, coat_of_arms: coat_upload(coat_png(512, 512))) }
      .not_to change(ActiveStorage::Blob, :count)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json).to eq("error" => "invalid_health_department_name")
    expect(city.reload.health_department_name).to be_nil
    expect(city.coat_of_arms).not_to be_attached
    expect(audits).to be_empty
  end

  it "120 caracteres passa" do
    patch_identity(health_department_name: "a" * 120)
    expect(response).to have_http_status(:ok)
  end

  it "SVG renomeado .png dá 422 invalid_format" do
    patch_identity(coat_of_arms: coat_upload('<svg xmlns="http://www.w3.org/2000/svg"/>'))
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json).to eq("error" => "invalid_format")
    expect(city.reload.coat_of_arms).not_to be_attached
  end

  it "coat_of_arms vazio (nenhum arquivo escolhido) não mexe no brasão e grava o nome" do
    patch_identity(coat_of_arms: coat_upload(coat_png(512, 512)))
    patch_identity(health_department_name: "Secretaria W", coat_of_arms: "")
    expect(response).to have_http_status(:ok)
    expect(json["city"]["health_department_name"]).to eq("Secretaria W")
    expect(json["city"]["coat_of_arms_url"]).to be_present
  end

  it "coat_of_arms que não é arquivo (texto ou hash) dá 422 invalid_format e não grava nada" do
    patch_identity(health_department_name: "Secretaria V", coat_of_arms: "foo")
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json).to eq("error" => "invalid_format")
    patch_identity(health_department_name: "Secretaria V", coat_of_arms: { a: "b" })
    expect(response).to have_http_status(:unprocessable_entity)
    expect(city.reload.health_department_name).to be_nil
    expect(audits).to be_empty
  end

  it "grande demais e dimensões fora dão 422 com a razão" do
    patch_identity(coat_of_arms: coat_upload(coat_png(512, 512, pad_to: 262_145)))
    expect(json).to eq("error" => "too_large")
    patch_identity(coat_of_arms: coat_upload(coat_png(100, 100)))
    expect(json).to eq("error" => "invalid_dimensions")
  end

  it "remove_coat_of_arms apaga blob e anexo na hora, sem job enfileirado" do
    patch_identity(coat_of_arms: coat_upload(coat_png(512, 512)))
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear

    expect { patch_identity(remove_coat_of_arms: "true") }.to change(ActiveStorage::Blob, :count).by(-1)
    expect(response).to have_http_status(:ok)
    expect(json["city"]["coat_of_arms_url"]).to be_nil
    expect(city.reload.coat_of_arms).not_to be_attached
    expect(enqueued).to be_empty
    expect(audits.last.payload).to include("fields" => %w[coat_of_arms])
  end

  it "funciona com a cidade em provisioning" do
    prov = create(:city, status: "provisioning")
    patch_identity({ health_department_name: "Secretaria Y", coat_of_arms: coat_upload(coat_png(512, 512)) }, id: prov.id)
    expect(response).to have_http_status(:ok)
    expect(prov.reload.coat_of_arms).to be_attached
  end

  it "cidade inexistente: 404" do
    patch_identity({ health_department_name: "x" }, id: SecureRandom.uuid)
    expect(response).to have_http_status(:not_found)
  end

  it "exige operador autenticado (sem sessão: 401)" do
    delete "/session"
    patch_identity(health_department_name: "x")
    expect(response).to have_http_status(:unauthorized)
  end

  it "GET /cities/:id traz health_department_name e coat_of_arms_url" do
    get "/cities/#{city.id}"
    expect(json).to include("health_department_name" => nil, "coat_of_arms_url" => nil)
    patch_identity(health_department_name: "Secretaria Z", coat_of_arms: coat_upload(coat_png(512, 512)))
    get "/cities/#{city.id}"
    expect(json["health_department_name"]).to eq("Secretaria Z")
    expect(json["coat_of_arms_url"]).to start_with("/city_identity/coat_of_arms?v=")
  end
end
