require "rails_helper"

RSpec.describe Integrations::SetCredential do
  let!(:city) { vaccination_city! }
  let(:admin) { pharmacy_admin! }
  let(:pfx) { self_signed_pfx(password: "segredo", not_after: 1.year.from_now) }

  def secret(pfx_bytes, password: "segredo", cnes: "1234567")
    { "pfx_base64" => Base64.strict_encode64(pfx_bytes), "pfx_password" => password, "requester_cnes" => cnes }
  end

  def reason_for(body) = described_class.call(kind: "rnds", secret: body, by: admin, city: city).reason

  it "grava o PFX cifrado, nunca devolve, e audita na plataforma só com city_id" do
    result = described_class.call(kind: "rnds", secret: secret(pfx), by: admin, city: city)
    expect(result).to be_ok
    credential = IntegrationCredential.find_by(kind: "rnds")
    expect(credential.requester_cnes).to eq("1234567")
    expect(credential.pfx_bytes).to eq(pfx)
    expect(PlatformEvent.where(name: "rnds.credential_set").last.payload).to eq("city_id" => city.id)
  end

  it "recusa forma, PFX que não abre e certificado vencido" do
    expect(reason_for({ "pfx_base64" => "x", "pfx_password" => "segredo" })).to eq(:invalid_credential)
    expect(reason_for(secret("lixo", password: "s"))).to eq(:invalid_certificate)
    expect(reason_for(secret(pfx, password: "errada"))).to eq(:invalid_certificate)
    expect(reason_for(secret(self_signed_pfx(password: "s", not_after: 1.day.ago), password: "s"))).to eq(:certificate_expired)
    expect(IntegrationCredential.where(kind: "rnds")).to be_empty
    expect(PlatformEvent.where(name: "rnds.credential_set")).to be_empty
  end

  it "senha com byte NUL (ArgumentError do OpenSSL) é invalid_certificate, sem a mensagem do erro" do
    result = described_class.call(kind: "rnds", secret: secret(pfx, password: "seg\0redo"), by: admin, city: city)
    expect(result.reason).to eq(:invalid_certificate)
    expect([ result.message, result.details ].to_s).not_to include("null byte")
    expect(IntegrationCredential.where(kind: "rnds")).to be_empty
  end

  it "TypeError do OpenSSL também vira invalid_certificate" do
    allow(OpenSSL::PKCS12).to receive(:new).and_raise(TypeError, "no implicit conversion")
    expect(reason_for(secret(pfx))).to eq(:invalid_certificate)
  end

  it "recusa CNES fora de sete dígitos" do
    [ "123456", "12345678", "12345 7", "abcdefg", "1234567\n" ].each do |cnes|
      expect(reason_for(secret(pfx, cnes: cnes))).to eq(:invalid_requester_cnes), cnes.inspect
    end
  end

  it "aceita até 100 KB decodificados; acima disso, invalid_credential" do
    limit = IntegrationCredential::PFX_MAX_BYTES
    # Só o limite importa antes de abrir o PFX: no limite passa da forma e cai em invalid_certificate.
    expect(reason_for(secret("a" * limit))).to eq(:invalid_certificate)
    expect(reason_for(secret("a" * (limit + 1)))).to eq(:invalid_credential)
  end

  it "ledi continua { username, password }" do
    expect(described_class.call(kind: "ledi", secret: { "username" => "rota", "password" => "s" }, by: admin, city: city)).to be_ok
    expect(described_class.call(kind: "ledi", secret: { "username" => "rota", "password" => " " }, by: admin, city: city).reason).to eq(:invalid_credential)
    expect(PlatformEvent.where(name: "rnds.credential_set")).to be_empty
  end
end
