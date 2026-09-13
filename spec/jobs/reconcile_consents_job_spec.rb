require "rails_helper"

# Caracterização (Ruling R12/R31): prende o contrato do job ANTES de remover a
# dimensão de município. As asserções (linha de log com current/stale_active,
# nenhuma mutação de consentimento) NÃO mudam quando o corpo muda — só o harness
# e a montagem dos dados mudam junto com o schema.
#
# Harness desta versão: o corpo ATUAL itera Municipality e filtra
# consents.municipality_id, que o schema de cidade não tem. Para caracterizá-lo
# verde, o exemplo roda contra o schema PRÉ-CORTE que ainda existe no banco de
# teste compartilhado (rota_saude_test, tabelas vazias), dentro da transação das
# fixtures (rollback ao final — nada persiste).
RSpec.describe ReconcileConsentsJob, type: :job do
  LEGACY_CONSENTS_SCHEMA = CityTestDatabases.city("legacyconsents", "rota_saude_test").freeze

  CONSENT_MODELS = [Municipality, Conversation, Consent, ConsentTerm].freeze

  before(:context) { CityConnection.ensure_pool(LEGACY_CONSENTS_SCHEMA) }

  around do |example|
    within_city(LEGACY_CONSENTS_SCHEMA) do
      CONSENT_MODELS.each(&:reset_column_information)
      example.run
    ensure
      CONSENT_MODELS.each(&:reset_column_information)
    end
  end

  # — montagem (muda com o schema; as asserções abaixo não) —

  def municipality
    @municipality ||= Municipality.create!(name: "Char Consent City", slug: "char-consent-city")
  end

  def consent_term!(version)
    ConsentTerm.create!(municipality: municipality, version: version, body: "termo", published_at: Time.current)
  end

  def consent!(phone, version:, revoked: false)
    conversation = Conversation.create!(municipality: municipality, phone: phone, state: "consented")
    Consent.create!(
      conversation: conversation, version: version, policy_text_sha: "sha", channel: "whatsapp",
      given_at: 2.days.ago, revoked_at: (revoked ? 1.day.ago : nil)
    )
  end

  def run_body
    described_class.instance_method(:perform).super_method.bind_call(described_class.new)
  end

  def reconcile_lines
    lines = []
    allow(Rails.logger).to receive(:info).and_call_original
    allow(Rails.logger).to receive(:info).with(a_string_starting_with("[reconcile_consents]")) { |msg| lines << msg }
    run_body
    lines
  end

  def consent_snapshot
    Consent.order(:id).pluck(:id, :version, :revoked_at, :updated_at)
  end

  it "without a consent term, treats version 1 as current and counts only active consents on another version" do
    consent!("+5541980000001", version: 1)
    consent!("+5541980000002", version: 0)
    consent!("+5541980000003", version: 0, revoked: true)

    lines = reconcile_lines

    expect(lines.size).to eq(1)
    expect(lines.first).to include("current=1 stale_active=1")
  end

  it "uses the highest consent term version as current" do
    consent_term!("2")
    consent!("+5541980000011", version: 2)
    consent!("+5541980000012", version: 1)
    consent!("+5541980000013", version: 1)
    consent!("+5541980000014", version: 1, revoked: true)

    lines = reconcile_lines

    expect(lines.size).to eq(1)
    expect(lines.first).to include("current=2 stale_active=2")
  end

  it "only reports — it does not change any consent" do
    consent!("+5541980000021", version: 0)
    consent!("+5541980000022", version: 1)
    before_run = consent_snapshot

    reconcile_lines

    expect(consent_snapshot).to eq(before_run)
  end
end
