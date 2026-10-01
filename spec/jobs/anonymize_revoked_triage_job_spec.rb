require "rails_helper"

RSpec.describe AnonymizeRevokedTriageJob, type: :job do
  # Same slug/database_url as TEST_CITY_A: with_city(city.slug) then re-enters
  # the shard the harness already has open, so fixtures created below on the
  # default connection and the job's own with_city block share one session
  # (a distinct random shard pointed at the same physical database would be a
  # second, separate Postgres session — see idempotent_consumer_transaction_spec.rb
  # for the pattern that keeps the two apart on purpose).
  let!(:city) do
    create(:city, slug: TEST_CITY_A.slug, status: "active", database_url: city_database_url("rota_saude_test_city_a"))
  end

  def definition_hash
    {
      "name" => "rev-demo", "version" => 1, "start_step_id" => "s1",
      "steps" => [{ "id" => "s1", "prompt" => "?", "answer_type" => "boolean",
                    "branches" => { "true" => nil, "false" => nil } }],
      "scoring" => { "type" => "weighted", "thresholds" => { "baixa" => 0 } }
    }
  end

  def event_args(conversation_id, event_id: SecureRandom.uuid)
    { event_id: event_id, event_name: "consent.revoked", city_slug: city.slug,
      payload: { "conversation_id" => conversation_id, "consent_id" => SecureRandom.uuid, "reason" => "revogar" } }
  end

  it "scrubs clinical fields of the aborted_by_revocation triage, keeps the audit shell" do
    pd = ProtocolDefinition.create!(name: "rev-demo", version: 1, status: "active", definition: definition_hash)
    convo = Conversation.create!(phone: "+551133", state: "revoked")
    triage = Triage.create!(conversation: convo, protocol_definition: pd, protocol_name: "rev-demo",
                            status: "aborted_by_revocation",
                            answers: { "s1" => "true" }, outcome: { "tier" => "baixa" },
                            tier: "baixa", priority: 9, current_step: "s1", completed_at: Time.current)

    described_class.new.perform(**event_args(convo.id))

    t = Triage.find(triage.id)
    expect(t.answers).to eq({})
    expect(t.outcome).to be_nil
    expect(t.tier).to be_nil
    expect(t.priority).to be_nil
    expect(t.current_step).to be_nil
    expect(t.status).to eq("aborted_by_revocation")
    expect(t.protocol_name).to eq("rev-demo")
    expect(t.completed_at).to be_present
  end

  it "is idempotent across distinct deliveries (scrub of already-empty is a no-op)" do
    pd = ProtocolDefinition.create!(name: "rev-demo", version: 1, status: "active", definition: definition_hash)
    convo = Conversation.create!(phone: "+551134", state: "revoked")
    Triage.create!(conversation: convo, protocol_definition: pd, protocol_name: "rev-demo",
                   status: "aborted_by_revocation", answers: { "s1" => "true" }, tier: "baixa")

    described_class.new.perform(**event_args(convo.id))
    expect {
      described_class.new.perform(**event_args(convo.id)) # distinct event_id
    }.not_to raise_error

    expect(Triage.where(conversation_id: convo.id).first.answers).to eq({})
  end

  it "does not touch a completed triage or another conversation's triage" do
    pd = ProtocolDefinition.create!(name: "rev-demo", version: 1, status: "active", definition: definition_hash)
    target = Conversation.create!(phone: "+551135", state: "revoked")
    target_triage = Triage.create!(conversation: target, protocol_definition: pd, protocol_name: "rev-demo",
                                   status: "aborted_by_revocation", answers: { "s1" => "true" })
    completed_convo = Conversation.create!(phone: "+551136", state: "completed")
    done = Triage.create!(conversation: completed_convo, protocol_definition: pd, protocol_name: "rev-demo",
                          status: "completed", answers: { "s1" => "true" }, tier: "baixa")

    described_class.new.perform(**event_args(target.id))

    # Fix round 1 (M3) — positive control: prove the job actually ran and did
    # its job on the TARGET row first. Without this, a misaligned city_slug
    # (CityMissing/CityNotServable swallowed, or a silent no-op) would leave
    # every row — including `done` — untouched, and the assertion below would
    # pass vacuously for the wrong reason.
    expect(Triage.find(target_triage.id).answers).to eq({})
    expect(Triage.find(done.id).answers).to eq({ "s1" => "true" }) # completed untouched
  end

  # ADR 0023, decisão de 2026-09-28: revogar apaga também o bairro copiado.
  it "zera o bairro da triagem revogada e não toca a de outra conversa" do
    pd = ProtocolDefinition.create!(name: "rev-demo", version: 1, status: "active", definition: definition_hash)
    centro = Neighborhood.create!(name: "Centro", source: "seed")
    convo = Conversation.create!(phone: "+551133", state: "revoked")
    revoked = Triage.create!(conversation: convo, protocol_definition: pd, protocol_name: "rev-demo",
                             status: "aborted_by_revocation", answers: {}, neighborhood_id: centro.id,
                             completed_at: Time.current)
    other = Triage.create!(conversation: Conversation.create!(phone: "+551144", state: "completed"),
                           protocol_definition: pd, protocol_name: "rev-demo", status: "completed",
                           answers: {}, neighborhood_id: centro.id, completed_at: Time.current)

    described_class.new.perform(**event_args(convo.id))

    expect(revoked.reload.neighborhood_id).to be_nil
    expect(other.reload.neighborhood_id).to eq(centro.id)
  end

  # ADR 0024 §5.6: a revogação da conversa MAIS RECENTE do cidadão apaga as
  # linhas dele em campaign_recipients; os contadores da campanha não mudam.
  it "revogar a conversa mais recente apaga as linhas de campanha do cidadão; conversa antiga não" do
    citizen = Citizen.create!(cpf: "52998224725", phone: "+5541998765432")
    old = Conversation.create!(channel: "web", citizen: citizen, phone: citizen.phone, state: "revoked",
                               created_at: 3.days.ago)
    latest = Conversation.create!(channel: "web", citizen: citizen, phone: citizen.phone, state: "revoked",
                                  created_at: 1.day.ago)
    campaign = sent_campaign!
    recipient!(campaign, citizen, sms_status: "not_opted_in")
    other = recipient!(campaign, Citizen.create!(cpf: "11144477735", phone: "+5541998765433"), sms_status: "not_opted_in")

    described_class.new.perform(**event_args(old.id))
    expect(CampaignRecipient.where(citizen_id: citizen.id).count).to eq(1)

    described_class.new.perform(**event_args(latest.id))
    expect(CampaignRecipient.where(citizen_id: citizen.id)).to be_empty
    expect(other.reload).to be_present
    expect(campaign.reload).to have_attributes(recipients_count: 0, phones_count: 0, status: "sent")
  end

  it "conversa sem cidadão (WhatsApp antigo): nada a apagar" do
    convo = Conversation.create!(phone: "+551135", state: "revoked")
    expect(Campaigns::ForgetRevokedRecipients.call(conversation_id: convo.id)).to eq(0)
    expect { described_class.new.perform(**event_args(convo.id)) }.not_to raise_error
  end

  # ADR 0026: a revogação anonimiza também a triagem concluída sem atendimento.
  describe "triagem concluída (ADR 0026)" do
    let(:centro) { Neighborhood.create!(name: "Centro", source: "seed") }
    # O bairro é copiado do cidadão no início da triagem (ADR 0023).
    let(:citizen) { Citizen.create!(cpf: "52998224725", phone: "+5541998765432", neighborhood: centro) }
    let!(:triage) { completed_web_triage_for(citizen) }
    let(:conversation) { triage.conversation }
    let(:staff) { User.create!(email_address: "s-#{SecureRandom.hex(3)}@x.com", password: "secret123") }

    it "anonimiza a concluída sem atendimento, com bairro e anonymized_at" do
      expect(triage.neighborhood_id).to eq(centro.id)
      described_class.new.handle(conversation_id: conversation.id)

      triage.reload
      expect(triage.status).to eq("completed")
      expect([triage.answers, triage.outcome, triage.tier, triage.priority, triage.neighborhood_id])
        .to eq([{}, nil, nil, nil, nil])
      expect(triage.anonymized_at).to be_present
    end

    it "não toca a concluída que virou atendimento" do
      Attendance.create!(triage: triage, citizen: citizen, health_unit: create_unit, checked_in_by_user: staff,
                         checked_in_at: Time.current, check_in_method: "code")
      expect { described_class.new.handle(conversation_id: conversation.id) }.not_to(change { triage.reload.attributes })
    end

    it "é idempotente" do
      described_class.new.handle(conversation_id: conversation.id)
      expect { described_class.new.handle(conversation_id: conversation.id) }.not_to(change { triage.reload.anonymized_at })
    end

    it "Triages::Anonymize.clear! limpa sem checar atendimento e preserva anonymized_at existente" do
      Attendance.create!(triage: triage, citizen: citizen, health_unit: create_unit, checked_in_by_user: staff,
                         checked_in_at: Time.current, check_in_method: "code")
      Triages::Anonymize.clear!(triage)
      first = triage.reload.anonymized_at
      expect(first).to be_present
      expect([triage.answers, triage.outcome, triage.tier]).to eq([{}, nil, nil])
      Triages::Anonymize.clear!(triage)
      expect(triage.reload.anonymized_at).to eq(first)
    end
  end
end
