require "rails_helper"

RSpec.describe GenerateReportJob do
  include ActiveSupport::Testing::TimeHelpers

  def definition_hash(with_recs:)
    base = {
      "name" => "triagem-rec",
      "version" => 1,
      "start_step_id" => "tosse",
      "steps" => [
        { "id" => "tosse", "prompt" => "Tosse?", "answer_type" => "boolean",
          "branches" => { "true" => nil, "false" => nil }, "weights" => { "true" => 5, "false" => 0 } }
      ],
      "scoring" => { "type" => "weighted", "thresholds" => { "baixa" => 0, "alta" => 5 },
                     "priority_map" => { "baixa" => 9, "alta" => 1 } }
    }
    return base unless with_recs
    base.merge("recommendations" => {
      "alta"  => { "title" => "Procure atendimento hoje", "body" => "Seus sintomas indicam prioridade alta." },
      "baixa" => { "title" => "Cuidados em casa", "body" => "Mantenha repouso e hidratacao." }
    })
  end

  def build_triage(tier:, with_recs:)
    pd = ProtocolDefinition.create!(
      name: "triagem-rec", version: 1, status: "active",
      definition: definition_hash(with_recs: with_recs)
    )
    convo = Conversation.create!(phone: "+5511999990000", state: "greeting")
    Triage.create!(
      conversation: convo, protocol_definition: pd, protocol_name: "triagem-rec",
      status: "completed", tier: tier, priority: 1,
      completed_at: Time.current,
      outcome: { "trail" => [{ "step" => "tosse", "answer" => "true" }] }
    )
  end

  # Was an `around` opening a transaction with SET LOCAL app.municipality_id (RLS).
  # Removed in 5c-1: raising before `ex.run` (e.g. `muni`) skipped rspec-rails'
  # fixture teardown and leaked the pinned transaction into the rest of the suite.
  # The example already runs inside TEST_CITY_A's connection and its fixture transaction.
  before { Current.city = TEST_CITY_A }

  after { Current.reset }

  it "freezes the tier's recommendation into the payload" do
    triage = build_triage(tier: "alta", with_recs: true)
    GenerateReportJob.new.handle(triage_id: triage.id, **triage.outcome.symbolize_keys)
    snap = ReportSnapshot.find_by!(triage_id: triage.id)
    expect(snap.payload["recommendation"]).to eq(
      "title" => "Procure atendimento hoje", "body" => "Seus sintomas indicam prioridade alta."
    )
  end

  # F-03.17: o link /r/:token é público (30 dias, sem login). O snapshot não
  # guarda as respostas do cidadão — só tier, prioridade e recomendação.
  it "never freezes the citizen's answers into the payload" do
    triage = build_triage(tier: "alta", with_recs: true)
    GenerateReportJob.new.handle(triage_id: triage.id, **triage.outcome.symbolize_keys)
    snap = ReportSnapshot.find_by!(triage_id: triage.id)
    expect(snap.payload.keys).to contain_exactly("tier", "priority", "recommendation", "completed_at")
    expect(snap.payload.to_json).not_to include("answer")
  end

  it "freezes nil when the protocol has no recommendations" do
    triage = build_triage(tier: "alta", with_recs: false)
    GenerateReportJob.new.handle(triage_id: triage.id, **triage.outcome.symbolize_keys)
    snap = ReportSnapshot.find_by!(triage_id: triage.id)
    expect(snap.payload).to have_key("recommendation")
    expect(snap.payload["recommendation"]).to be_nil
  end

  # O snapshot congela a versão por REFERÊNCIA (ADR 0010: protocol_definition_id
  # é a "versão exata usada"; não existe coluna protocol_version): a da
  # triagem, não a vigente no momento da geração.
  it "records the protocol_definition_id the triage ran under, even after another version is active" do
    triage = build_triage(tier: "alta", with_recs: true)
    ran_under = triage.protocol_definition
    ran_under.update!(status: "published")
    ProtocolDefinition.create!(name: "triagem-rec", version: 2, status: "active",
                               definition: definition_hash(with_recs: true).merge("version" => 2))

    GenerateReportJob.new.handle(triage_id: triage.id, **triage.outcome.symbolize_keys)

    expect(ReportSnapshot.find_by!(triage_id: triage.id).protocol_definition_id).to eq(ran_under.id)
  end

  it "expires the link 30 days after generation by default" do
    triage = build_triage(tier: "alta", with_recs: true)
    freeze_time do
      GenerateReportJob.new.handle(triage_id: triage.id, **triage.outcome.symbolize_keys)
      expect(ReportSnapshot.find_by!(triage_id: triage.id).expires_at).to eq(30.days.from_now)
    end
  end

  # Reentrega (ADR 0005) pelo perform completo: o mesmo event_id é deduplicado
  # pelo IdempotentConsumer; um event_id NOVO para a mesma triagem (replay,
  # evento republicado) cai na guarda `return if triage.report_snapshot` — e o
  # índice único por triagem é a última linha de defesa.
  describe "redelivery" do
    let!(:city) { create(:city, slug: TEST_CITY_A.slug, database_url: city_database_url("rota_saude_test_city_a")) }

    def deliver(triage, event_id:)
      described_class.perform_now(event_id: event_id, event_name: "triage.completed", city_slug: city.slug,
                                  payload: { "triage_id" => triage.id, "tier" => triage.tier })
    end

    it "does not create a second snapshot for the same event" do
      triage = build_triage(tier: "alta", with_recs: true)
      event_id = SecureRandom.uuid

      deliver(triage, event_id: event_id)
      first = ReportSnapshot.find_by!(triage_id: triage.id)
      deliver(triage, event_id: event_id)

      expect(ReportSnapshot.where(triage_id: triage.id).pluck(:id)).to eq([ first.id ])
    end

    it "does not create a second snapshot, nor change the first, for a new event of the same triage" do
      triage = build_triage(tier: "alta", with_recs: true)

      deliver(triage, event_id: SecureRandom.uuid)
      first = ReportSnapshot.find_by!(triage_id: triage.id)
      expect { deliver(triage, event_id: SecureRandom.uuid) }.not_to raise_error

      expect(ReportSnapshot.where(triage_id: triage.id).pluck(:id, :token)).to eq([ [ first.id, first.token ] ])
    end
  end
end
