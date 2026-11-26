require "rails_helper"

# Módulo 26c (Q13): validação do segredo da `rnds_regulation` no comando. As
# recusas não gravam, então rodam já; a gravação depende do CHECK de `kind`
# da migração da Task 5.
RSpec.describe Integrations::SetCredential do
  let!(:city) { vaccination_city! }
  let(:admin) { pharmacy_admin! }
  let(:pfx) { self_signed_pfx(password: "segredo", not_after: 1.year.from_now) }
  let(:cns) { valid_cns(26) }

  def secret(**over)
    { "pfx_base64" => Base64.strict_encode64(pfx), "pfx_password" => "segredo", "requester_cnes" => "1234567",
      "requester_id" => "2926", "responsible_cns" => cns }.merge(over.transform_keys(&:to_s))
  end

  def reason_for(body) = described_class.call(kind: "rnds_regulation", secret: body, by: admin, city: city).reason

  it "recusa requester_id fora de dígitos e CNS inválido, sem gravar nem auditar" do
    expect(reason_for(secret(requester_id: "12 34"))).to eq(:invalid_requester_id)
    expect(reason_for(secret(requester_id: "A123"))).to eq(:invalid_requester_id)
    expect(reason_for(secret(requester_id: "1" * 21))).to eq(:invalid_requester_id)
    expect(reason_for(secret(responsible_cns: "123"))).to eq(:invalid_responsible_cns)
    expect(reason_for(secret(responsible_cns: cns[0..-2] + ((cns[-1].to_i + 1) % 10).to_s))).to eq(:invalid_responsible_cns)
    expect(IntegrationCredential.where(kind: "rnds_regulation")).to be_empty
    expect(PlatformEvent.where(name: "rnds_regulation.credential_set")).to be_empty
  end

  it "sem as chaves novas: invalid_credential; PFX e CNES seguem validados" do
    expect(reason_for(secret.except("responsible_cns"))).to eq(:invalid_credential)
    expect(reason_for(secret.except("requester_id"))).to eq(:invalid_credential)
    expect(reason_for(secret(requester_cnes: "12"))).to eq(:invalid_requester_cnes)
    expect(reason_for(secret(pfx_password: "errada"))).to eq(:invalid_certificate)
  end

  it "a rnds não exige as chaves novas" do
    body = secret.slice("pfx_base64", "pfx_password", "requester_cnes")
    expect(described_class.validate_rnds(body)).to be_nil
    expect(described_class.validate_rnds(body, kind: "rnds_regulation")).to eq(:invalid_credential)
  end

  it "grava, guarda só as cinco chaves e audita na plataforma só com city_id" do
    pending "o CHECK ck_integration_credentials_kind aceita rnds_regulation só na migração da Task 5"
    result = described_class.call(kind: "rnds_regulation", secret: secret.merge("extra" => "x"), by: admin, city: city)
    expect(result).to be_ok
    credential = IntegrationCredential.find_by!(kind: "rnds_regulation")
    expect(credential.secret.keys.sort).to eq(IntegrationCredential::SECRET_KEYS["rnds_regulation"])
    expect(credential).to have_attributes(requester_id: "2926", responsible_cns: cns)
    expect(PlatformEvent.where(name: "rnds_regulation.credential_set").last.payload).to eq("city_id" => city.id)
    expect(PlatformEvent.where(name: "rnds.credential_set")).to be_empty
  end
end
