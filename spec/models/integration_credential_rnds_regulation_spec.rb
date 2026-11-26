require "rails_helper"

# Módulo 26c (Q13): a credencial `rnds_regulation` leva as três chaves da `rnds`
# mais o identificador do solicitante (só dígitos) e o CNS do responsável.
# A gravação (CHECK de `kind`, migração da Task 5) é provada em
# spec/models/regulation_rnds_schema_spec.rb; aqui, só `valid?`.
RSpec.describe IntegrationCredential, type: :model do
  let!(:city) { vaccination_city! }
  let(:admin) { pharmacy_admin! }
  let(:pfx_b64) { Base64.strict_encode64(self_signed_pfx(password: "segredo", not_after: 1.year.from_now)) }
  let(:cns) { valid_cns(26) }
  let(:secret) do
    { "pfx_base64" => pfx_b64, "pfx_password" => "segredo", "requester_cnes" => "1234567",
      "requester_id" => "2926", "responsible_cns" => cns }
  end

  def build_credential(body) = described_class.new(kind: "rnds_regulation", secret: body, set_by_user: admin, set_at: Time.current)

  it "segredo com as cinco chaves passa" do
    expect(build_credential(secret)).to be_valid
  end

  it "sem responsible_cns (ou sem requester_id) é inválido" do
    expect(build_credential(secret.except("responsible_cns"))).not_to be_valid
    expect(build_credential(secret.except("requester_id"))).not_to be_valid
  end

  it "CNS com dígito errado é inválido" do
    wrong = cns[0..-2] + ((cns[-1].to_i + 1) % 10).to_s
    expect(build_credential(secret.merge("responsible_cns" => wrong))).not_to be_valid
  end

  it "requester_id só com dígitos, até 20" do
    expect(build_credential(secret.merge("requester_id" => "12 34"))).not_to be_valid
    expect(build_credential(secret.merge("requester_id" => "AB12"))).not_to be_valid
    expect(build_credential(secret.merge("requester_id" => "1" * 21))).not_to be_valid
    expect(build_credential(secret.merge("requester_id" => "1" * 20))).to be_valid
  end

  it "a rnds continua com as três chaves: as duas a mais a invalidam" do
    rnds = described_class.new(kind: "rnds", secret: secret.slice("pfx_base64", "pfx_password", "requester_cnes"),
                               set_by_user: admin, set_at: Time.current)
    expect(rnds).to be_valid
    expect(described_class.new(kind: "rnds", secret: secret, set_by_user: admin, set_at: Time.current)).not_to be_valid
  end

  it "leitores e inspect sem nenhum valor" do
    credential = build_credential(secret)
    expect(credential).to have_attributes(requester_id: "2926", responsible_cns: cns, requester_cnes: "1234567")
    expect(credential.inspect).not_to include(cns, "2926", "1234567", "segredo", pfx_b64[0, 40])
  end
end
