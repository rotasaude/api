# spec/commands/citizens/start_conversation_concurrency_spec.rb
require "rails_helper"

# Review Focus 4 (ADR 0027 §5.2): dois toques ou duas abas ao mesmo tempo.
# Threads reais contra TEST_CITY_A (sem fixture transacional), como
# spec/commands/attendances/call_next_concurrency_spec.rb; o after apaga o que
# commitou.
RSpec.describe Citizens::StartConversation, "concorrência" do
  self.use_transactional_tests = false

  let(:ids) { {} }

  def in_city(&block) = CityConnection.with(TEST_CITY_A) { Current.set(city: TEST_CITY_A, &block) }

  before do
    in_city do
      ids[:started_at] = Time.current
      tag = SecureRandom.hex(4)
      ids[:names] = [ "corrida-a-#{tag}", "corrida-b-#{tag}" ]
      ids[:protocols] = ids[:names].map { |name| active_protocol!(name).id }
      citizen = Citizen.create!(cpf: CampaignHistory.cpf_for("corrida-#{tag}"),
                                phone: "+55419#{format('%08d', 30_000_000 + SecureRandom.random_number(1_000_000))}",
                                birth_date: birth_date_for(40), sex: "female", profile_source: "declared")
      ids[:citizen] = citizen.id
    end
  end

  after do
    in_city do
      ApplicationRecord.transaction do
        ApplicationRecord.connection.execute("SET LOCAL session_replication_role = replica")
        conversation_ids = Conversation.where(citizen_id: ids[:citizen]).pluck(:id)
        Triage.where(conversation_id: conversation_ids).delete_all
        Consent.where(conversation_id: conversation_ids).delete_all
        Conversation.where(id: conversation_ids).delete_all
        Citizen.where(id: ids[:citizen]).delete_all
        ProtocolDefinition.where(id: ids[:protocols]).delete_all
        DomainEvent.where("occurred_at >= ?", ids[:started_at]).delete_all
      end
    end
    Rails.cache.clear
  end

  def race(*names)
    go = Queue.new
    threads = names.map do |name|
      Thread.new do
        in_city do
          go.pop
          described_class.call(citizen: Citizen.find(ids[:citizen]), consent_version: Consents.current_version,
                               session_id: "corrida", protocol_name: name)
        end
      end
    end
    names.size.times { go << true }
    threads.map { |t| t.join(10) ? t.value : raise("thread presa") }
  end

  def triages = in_city { Triage.joins(:conversation).where(conversations: { citizen_id: ids[:citizen] }).count }

  it "o mesmo protocolo duas vezes: uma triagem, a outra retoma" do
    results = race(ids[:names].first, ids[:names].first)
    expect(results.map { |r| r.payload[:resumed] }).to contain_exactly(false, true)
    expect(triages).to eq(1)
  end

  it "protocolos diferentes: uma triagem e um :triage_in_progress" do
    results = race(*ids[:names])
    expect(results.map(&:reason)).to contain_exactly(nil, :triage_in_progress)
    expect(triages).to eq(1)
  end
end
