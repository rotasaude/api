require "rails_helper"

# Lifecycle de protocolo per-cidade (ADR-0009): publish ≠ active.
# Cobre as quatro invariantes INV-protocol-1..4.
RSpec.describe "Protocols lifecycle" do
  let(:muni) { create(:municipality) }

  let(:publisher) do
    u = User.create!(email_address: "pub@example.org", password: "secret123")
    Membership.create!(user: u, municipality: muni, role: "protocol_publisher", granted_at: Time.current)
    u
  end

  let(:definition_hash) do
    {
      "name" => "dengue", "version" => 1, "start_step_id" => "s1",
      "steps" => [
        { "id" => "s1", "prompt" => "?", "answer_type" => "boolean",
          "branches" => { "true" => nil, "false" => nil }, "weights" => { "true" => 1, "false" => 0 } }
      ],
      "scoring" => { "type" => "weighted", "thresholds" => { "baixa" => 0 }, "priority_map" => { "baixa" => 9 } }
    }
  end

  def make_pd(version:, status:)
    ProtocolDefinition.create!(
      municipality_id: muni.id, name: "dengue", version: version,
      status: status, definition: definition_hash.merge("version" => version)
    )
  end

  around do |ex|
    ApplicationRecord.transaction do
      Current.municipality_id = muni.id
      ApplicationRecord.connection.execute(
        ApplicationRecord.sanitize_sql(["SET LOCAL app.municipality_id = ?", muni.id])
      )
      ex.run
      raise ActiveRecord::Rollback
    end
  end

  after { Current.reset; Rails.cache.clear }

  describe "INV-protocol-1 (R1): só uma versão published vira active" do
    it "ativar uma versão draft falha com :not_published" do
      make_pd(version: 1, status: "draft")
      result = Protocols::Activate.call(version: 1, by: publisher)
      expect(result.failure?).to be true
      expect(result.reason).to eq(:not_published)
    end

    it "ativar uma versão published sucede e vira active" do
      make_pd(version: 1, status: "published")
      result = Protocols::Activate.call(version: 1, by: publisher)
      expect(result.ok?).to be true
      expect(ProtocolDefinition.find_by(version: 1).status).to eq("active")
    end
  end

  describe "INV-protocol-2: uma active por (municipality_id, name)" do
    it "ativar v2 demove a v1 active para published (resta exatamente uma active)" do
      v1 = make_pd(version: 1, status: "active")
      v2 = make_pd(version: 2, status: "published")

      Protocols::Activate.call(version: 2, by: publisher)

      expect(v1.reload.status).to eq("published")
      expect(v2.reload.status).to eq("active")
      expect(
        ProtocolDefinition.where(municipality_id: muni.id, name: "dengue", status: "active").count
      ).to eq(1)
    end
  end

  describe "INV-protocol-3: triagem termina na versão em que começou" do
    it "ativar nova versão não altera a versão de uma triagem em voo" do
      v1 = make_pd(version: 1, status: "active")
      conv = Conversation.create!(municipality_id: muni.id, phone: "+5511999999999", state: "consented")
      triagem = Triagem.create!(
        municipality_id: muni.id, conversation_id: conv.id,
        protocol_definition_id: v1.id, protocol_name: "dengue", status: "in_progress"
      )

      make_pd(version: 2, status: "published")
      Protocols::Activate.call(version: 2, by: publisher)

      expect(triagem.reload.protocol_definition_id).to eq(v1.id)
    end
  end

  describe "INV-protocol-4 (R4): retired nunca está active" do
    it "aposentar uma versão active falha com :active_in_city" do
      make_pd(version: 1, status: "active")
      result = Protocols::Retire.call(version: 1, by: publisher)
      expect(result.failure?).to be true
      expect(result.reason).to eq(:active_in_city)
    end

    it "aposentar uma versão published sucede" do
      make_pd(version: 1, status: "published")
      result = Protocols::Retire.call(version: 1, by: publisher)
      expect(result.ok?).to be true
      expect(ProtocolDefinition.find_by(version: 1).status).to eq("retired")
    end
  end

  describe "Publish: draft/in_review → published (publish ≠ active)" do
    it "publica uma versão draft para published, sem ativá-la" do
      make_pd(version: 1, status: "draft")
      result = Protocols::Publish.call(version: 1, by: publisher)
      expect(result.ok?).to be true
      pd = ProtocolDefinition.find_by(version: 1)
      expect(pd.status).to eq("published")
      expect(ProtocolDefinition.where(status: "active").count).to eq(0)
    end
  end
end
