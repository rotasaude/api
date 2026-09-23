require "rails_helper"
require Rails.root.join("lib/signature_crew").to_s

# A semente que torna o ciclo assinado percorrível em dev: autor, duas
# revisoras e publisher com TOTP fixo, mais um rascunho criado PELO command de
# autoria — é o command que grava a contribuição e o digest de que as
# assinaturas dependem. Roda na conexão da cidade corrente (TEST_CITY_A),
# como spec/lib/dashboard_demo_spec.rb.
RSpec.describe SignatureCrew do
  let(:slug) { "cidade-teste" }
  let(:password) { "dev-password" }

  def seed! = described_class.seed_current_city(slug: slug, password: password)

  def user(email_prefix) = User.find_by(email_address: "#{email_prefix}@#{slug}.demo")

  it "cria as quatro contas com o papel de cada uma" do
    out = seed!

    expect(out[:accounts].map { |a| a[:email] }).to eq([
      "autor@#{slug}.demo", "revisora1@#{slug}.demo", "revisora2@#{slug}.demo", "publisher@#{slug}.demo"
    ])
    expect(user("autor").memberships.active.pluck(:role)).to eq([ "protocol_author" ])
    expect(user("revisora1").memberships.active.pluck(:role)).to eq([ "protocol_reviewer" ])
    expect(user("revisora2").memberships.active.pluck(:role)).to eq([ "protocol_reviewer" ])
    expect(user("publisher").memberships.active.pluck(:role)).to eq([ "protocol_publisher" ])
  end

  it "deixa cada conta com TOTP pronto e com a senha de dev" do
    seed!

    described_class::MEMBERS.each do |member|
      account = user(member[:email_prefix])
      expect(account.mfa_enrolled?).to be(true)
      expect(account.authenticate(password)).to be_truthy
    end
  end

  it "devolve o otpauth de cada conta, com o segredo da conta" do
    out = seed!

    uri = out[:accounts].first[:otpauth_uri]
    expect(uri).to start_with("otpauth://totp/")
    secret = URI.decode_www_form(URI.parse(uri).query).to_h["secret"]
    expect(secret).to eq(user("autor").otp_secret)
  end

  it "não sobrescreve um TOTP já existente" do
    seed!
    account = user("autor")
    account.update!(otp_secret: ROTP::Base32.random)
    mine = account.reload.otp_secret

    seed!

    expect(user("autor").otp_secret).to eq(mine)
  end

  it "PROTOCOL_NAME vem do nome do template, não de um literal solto" do
    expect(described_class::PROTOCOL_NAME).to eq(CityTemplates.protocol.fetch(:name))
  end

  describe "ensure_draft (achar/criar um rascunho de verdade)" do
    it "sem nenhuma versão do protocolo, cria a v1 em rascunho pelo command, com a contribuição do autor" do
      out = seed!

      draft = ProtocolDefinition.find_by(name: described_class::PROTOCOL_NAME, version: 1)
      expect(draft).not_to be_nil
      expect(draft.status).to eq("draft")
      expect(out[:draft]).to eq(name: described_class::PROTOCOL_NAME, version: 1, status: "draft")
      expect(ProtocolContribution.where(protocol_definition: draft).pluck(:actor_kind, :actor_id))
        .to eq([ [ "user", user("autor").id ] ])
      expect(ProtocolContribution.find_by(protocol_definition: draft).content_digest).to eq(draft.content_digest)
    end

    it "com a v1 active (o caso do seed atual), cria a v2 em rascunho" do
      ProtocolDefinition.create!(name: described_class::PROTOCOL_NAME, version: 1, status: "active",
                                 definition: protocol_definition_hash(name: described_class::PROTOCOL_NAME))

      out = seed!

      draft = ProtocolDefinition.find_by(name: described_class::PROTOCOL_NAME, version: 2)
      expect(draft).not_to be_nil
      expect(draft.status).to eq("draft")
      expect(out[:draft]).to eq(name: described_class::PROTOCOL_NAME, version: 2, status: "draft")
    end

    it "com v1 active e v2 published, cria a v3 em rascunho" do
      ProtocolDefinition.create!(name: described_class::PROTOCOL_NAME, version: 1, status: "active",
                                 definition: protocol_definition_hash(name: described_class::PROTOCOL_NAME))
      ProtocolDefinition.create!(name: described_class::PROTOCOL_NAME, version: 2, status: "published",
                                 definition: protocol_definition_hash(name: described_class::PROTOCOL_NAME, version: 2))

      out = seed!

      draft = ProtocolDefinition.find_by(name: described_class::PROTOCOL_NAME, version: 3)
      expect(draft).not_to be_nil
      expect(draft.status).to eq("draft")
      expect(out[:draft]).to eq(name: described_class::PROTOCOL_NAME, version: 3, status: "draft")
    end

    it "com um rascunho já existente, devolve-o e NÃO cria outro nem reescreve (F2)" do
      seed!
      draft = ProtocolDefinition.find_by(name: described_class::PROTOCOL_NAME, status: "draft")
      original_digest = draft.content_digest
      original_contribution_count = ProtocolContribution.where(protocol_definition: draft).count

      out = seed!

      expect(ProtocolDefinition.where(name: described_class::PROTOCOL_NAME).count).to eq(1)
      expect(draft.reload.content_digest).to eq(original_digest)
      expect(ProtocolContribution.where(protocol_definition: draft).count).to eq(original_contribution_count)
      expect(out[:draft]).to eq(name: draft.name, version: draft.version, status: "draft")
    end
  end

  it "as duas revisoras são elegíveis para assinar o rascunho, e o autor não" do
    seed!
    draft = ProtocolDefinition.find_by(name: described_class::PROTOCOL_NAME, status: "draft")

    expect(Protocols::Signatures.eligible_reviewer_count(draft)).to eq(2)
    expect(Protocols::Signatures.valid_signer_ids(draft, purpose: "publication")).to eq([])
  end

  it "é idempotente: a segunda execução não duplica conta, papel nem contribuição" do
    first = seed!

    expect { seed! }.not_to change { User.count }
    expect { seed! }.not_to change { Membership.count }
    expect { seed! }.not_to change { ProtocolContribution.count }
    expect { seed! }.not_to change { ProtocolDefinition.where(name: described_class::PROTOCOL_NAME).count }
    expect(seed!).to eq(first)
  end

  it "não mexe no protocolo ativo da cidade" do
    active = ProtocolDefinition.create!(name: described_class::PROTOCOL_NAME, version: 1, status: "active",
                                        definition: protocol_definition_hash(name: described_class::PROTOCOL_NAME))

    seed!

    expect(active.reload.status).to eq("active")
  end
end
