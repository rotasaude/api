require "rails_helper"
require "json_schemer"

# F-14.6 (ADR 0025; spec 2026-09-30 §7): a marca `analytic` é da pergunta, só
# em boolean/enum, e o portão do ciclo assinado recusa o resto.
RSpec.describe "protocols schema.json analytic contract (F-14.6)" do
  let(:schema) { JSONSchemer.schema(JSON.parse(File.read(Rails.root.join("config/protocols/schema.json")))) }

  def definition(step)
    {
      "name" => "arbo-contract", "version" => 1, "start_step_id" => "s1",
      "steps" => [ { "id" => "s1", "prompt" => "?", "branches" => {}, "weights" => {} }.merge(step) ],
      "scoring" => { "type" => "weighted", "thresholds" => { "baixa" => 0 }, "priority_map" => { "baixa" => 9 } }
    }
  end

  it "aceita analytic em boolean e em enum, e analytic: false em qualquer tipo" do
    expect(schema.valid?(definition("answer_type" => "boolean", "analytic" => true))).to be(true)
    expect(schema.valid?(definition("answer_type" => "enum", "options" => %w[a b], "analytic" => true))).to be(true)
    expect(schema.valid?(definition("answer_type" => "integer", "analytic" => false))).to be(true)
    expect(schema.valid?(definition("answer_type" => "text"))).to be(true)
  end

  it "recusa analytic: true em integer e em text, e analytic que não é booleano" do
    expect(schema.valid?(definition("answer_type" => "integer", "analytic" => true))).to be(false)
    expect(schema.valid?(definition("answer_type" => "text", "analytic" => true))).to be(false)
    expect(schema.valid?(definition("answer_type" => "boolean", "analytic" => "sim"))).to be(false)
  end

  it "o portão do ciclo assinado aponta a pergunta marcada errada" do
    errors = Protocols::Gate.call(definition("answer_type" => "integer", "analytic" => true)).errors
    expect(errors).to include(a_string_including("/steps/0/answer_type"))
    expect(Protocols::Gate.call(definition("answer_type" => "boolean", "analytic" => true,
                                           "branches" => { "true" => nil, "false" => nil })).errors).to be_empty
  end

  # O api valida contra uma CÓPIA do schema do contracts, que não está dentro
  # do container. Igual a contracts protocols-v1.4.0 (aplicada à mão; conferir com a tag antes do merge); ao mudar,
  # copiar do contracts e atualizar o digest.
  it "config/protocols/schema.json é a cópia de contracts protocols-v1.4.0" do
    digest = Digest::SHA256.file(Rails.root.join("config/protocols/schema.json")).hexdigest
    expect(digest).to eq("08952cb6089472cc3da0259456c5ce785e2e08f3f3c50bcfe20deecd412c9c7c")
  end

  describe "a marca faz parte do conteúdo assinado (ADR 0016)" do
    before { Current.city = TEST_CITY_A }
    after { Current.reset }

    def flip_analytic(definition)
      definition.deep_dup.tap { |copy| copy["steps"][0]["analytic"] = !copy["steps"][0]["analytic"] }
    end

    it "em revisão: trocar só o analytic muda o digest e as assinaturas deixam de contar" do
      author = User.create!(email_address: "autora-#{SecureRandom.hex(3)}@example.org", password: "secret123")
      Membership.create!(user: author, role: "protocol_author", granted_at: Time.current)
      Protocols::SaveDraft.call(definition: protocol_definition_hash(name: "flag-sig"), by: author)
      protocol = ProtocolDefinition.find_by!(name: "flag-sig", version: 1)
      protocol.update!(status: "in_review")
      2.times { sign!(protocol, purpose: "publication", by: make_reviewer!) }
      expect(Protocols::Signatures.missing(protocol, purpose: "publication")).to eq(0)

      Protocols::SaveDraft.call(definition: flip_analytic(protocol.definition), by: author)

      expect(Protocols::Signatures.missing(protocol.reload, purpose: "publication")).to eq(2)
    end

    it "publicada: o trigger recusa trocar só o analytic" do
      protocol = ProtocolDefinition.create!(name: "flag-frozen", version: 1, status: "published",
                                            definition: protocol_definition_hash(name: "flag-frozen"))

      expect do
        ProtocolDefinition.transaction(requires_new: true) do
          ProtocolDefinition.where(id: protocol.id).update_all(definition: flip_analytic(protocol.definition))
        end
      end.to raise_error(ActiveRecord::StatementInvalid, /frozen once published/)
    end
  end
end
