require "rails_helper"

# A ÚNICA resposta para "esta versão tem as assinaturas?" (spec §5). Cada
# condição tem o seu exemplo: uma regra de aprovação que só é testada no
# caminho feliz aprova o que não devia.
RSpec.describe Protocols::Signatures do
  before { Current.city = TEST_CITY_A }
  after { Current.reset }

  let(:protocol) do
    ProtocolDefinition.create!(name: "dengue", version: 1, status: "in_review", definition: protocol_definition_hash)
  end
  let(:ana) { make_reviewer! }
  let(:bia) { make_reviewer! }

  it "counts two distinct reviewers on the current content" do
    sign!(protocol, purpose: "publication", by: ana)
    sign!(protocol, purpose: "publication", by: bia)

    expect(described_class.valid_signer_ids(protocol, purpose: "publication")).to contain_exactly(ana.id, bia.id)
    expect(described_class.missing(protocol, purpose: "publication")).to eq(0)
  end

  it "counts a reviewer once however many times they signed" do
    2.times { sign!(protocol, purpose: "publication", by: ana) }

    expect(described_class.missing(protocol, purpose: "publication")).to eq(1)
  end

  it "does not count a signature on older content" do
    sign!(protocol, purpose: "publication", by: ana)
    protocol.update!(definition: protocol_definition_hash.merge("start_step_id" => "s1", "note" => "x"))

    expect(described_class.valid_signer_ids(protocol, purpose: "publication")).to be_empty
  end

  it "does not count a signature for the other purpose" do
    sign!(protocol, purpose: "activation", by: ana)

    expect(described_class.valid_signer_ids(protocol, purpose: "publication")).to be_empty
  end

  it "does not count a reviewer whose role was revoked, nor a deactivated user" do
    sign!(protocol, purpose: "publication", by: ana)
    sign!(protocol, purpose: "publication", by: bia)
    ana.memberships.active.find_by!(role: "protocol_reviewer").update!(revoked_at: Time.current)
    bia.update!(deactivated_at: Time.current)

    expect(described_class.valid_signer_ids(protocol, purpose: "publication")).to be_empty
  end

  it "does not count a reviewer who contributed to the version, even after signing" do
    sign!(protocol, purpose: "publication", by: ana)
    ProtocolContribution.create!(protocol_definition: protocol, actor_id: ana.id, actor_kind: "user",
                                 content_digest: protocol.content_digest)

    expect(described_class.valid_signer_ids(protocol, purpose: "publication")).to be_empty
  end

  it "counts, for activation, only signatures after the version's last activation" do
    protocol.update!(status: "published")
    sign!(protocol, purpose: "activation", by: ana)
    ProtocolActivation.create!(protocol_definition: protocol, kind: "signed", actor_id: bia.id, actor_kind: "user")
    sign!(protocol, purpose: "activation", by: bia)

    expect(described_class.valid_signer_ids(protocol, purpose: "activation")).to contain_exactly(bia.id)
  end

  it "counts eligible reviewers as active reviewers who did not contribute" do
    ana
    bia
    ProtocolContribution.create!(protocol_definition: protocol, actor_id: ana.id, actor_kind: "user",
                                 content_digest: protocol.content_digest)

    expect(described_class.eligible_reviewer_count(protocol)).to eq(1)
    expect(described_class.shortfall_message(protocol, purpose: "publication"))
      .to eq("faltam 2 assinaturas de publicação; revisores elegíveis na cidade: 1")
  end
end
