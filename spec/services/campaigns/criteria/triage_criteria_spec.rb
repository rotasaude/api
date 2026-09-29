# spec/services/campaigns/criteria/triage_criteria_spec.rb
require "rails_helper"

# ADR 0024 §4.1: bordas do período inclusivas no fuso da cidade; a triagem chega
# ao cidadão por conversations.citizen_id; triagem sem cidadão não conta.
# Cada critério prova: entra, não entra, as duas bordas do período, sem cidadão.
RSpec.describe "Critérios de triagem" do
  before { create_default_protocol! }

  let(:from) { Time.zone.today - 30 }
  let(:to) { Time.zone.today - 10 }
  let(:first_instant) { from.in_time_zone.beginning_of_day }
  let(:last_instant) { to.in_time_zone.end_of_day }
  let(:inside) { first_instant + 2.days }
  let(:period) { { "from" => from.iso8601, "to" => to.iso8601 } }

  def ids(klass, params) = Citizen.where(id: klass.relation(params)).pluck(:id)

  it "registra os quatro kinds e calcula o período inclusivo" do
    expect(Campaigns::Criteria.for("triage_tier")).to eq(Campaigns::Criteria::TriageTier)
    expect(Campaigns::Criteria.period(period)).to eq(first_instant..last_instant)
  end

  describe Campaigns::Criteria::ProtocolPeriod do
    let(:params) { { "kind" => "protocol_period", "protocol_name" => "triage-respiratoria" }.merge(period) }

    it "entra quem concluiu triagem desse protocolo no período, com as bordas" do
      on_first = person!.tap { |c| CampaignHistory.triage!(c, at: first_instant) }
      on_last = person!.tap { |c| CampaignHistory.triage!(c, at: last_instant) }
      person!.tap { |c| CampaignHistory.triage!(c, at: first_instant - 1.second) }
      person!.tap { |c| CampaignHistory.triage!(c, at: last_instant + 1.second) }
      person!.tap { |c| CampaignHistory.triage!(c, protocol_name: "dengue", at: inside) }
      person!.tap { |c| CampaignHistory.triage!(c, status: "aborted_by_timeout", at: inside) }
      expect(ids(described_class, params)).to contain_exactly(on_first.id, on_last.id)
    end

    it "triagem sem cidadão não conta" do
      anonymous_triage!(at: inside)
      expect(ids(described_class, params)).to be_empty
    end
  end

  describe Campaigns::Criteria::TriageTier do
    let(:params) { { "kind" => "triage_tier", "tiers" => [ "alta" ] }.merge(period) }

    it "entra quem concluiu triagem com a faixa na lista, no período, com as duas bordas" do
      high = person!.tap { |c| CampaignHistory.triage!(c, tier: "alta", at: inside) }
      on_first = person!.tap { |c| CampaignHistory.triage!(c, tier: "alta", at: first_instant) }
      on_last = person!.tap { |c| CampaignHistory.triage!(c, tier: "alta", at: last_instant) }
      person!.tap { |c| CampaignHistory.triage!(c, tier: "baixa", at: inside) }
      person!.tap { |c| CampaignHistory.triage!(c, tier: "alta", at: first_instant - 1.second) }
      person!.tap { |c| CampaignHistory.triage!(c, tier: "alta", at: last_instant + 1.second) }
      person!.tap { |c| CampaignHistory.triage!(c, status: "aborted_by_timeout", at: inside) }
      expect(ids(described_class, params)).to contain_exactly(high.id, on_first.id, on_last.id)
    end

    it "triagem sem cidadão não conta" do
      anonymous_triage!(at: inside)
      expect(ids(described_class, params)).to be_empty
    end
  end

  describe Campaigns::Criteria::TriageIncomplete do
    let(:params) { { "kind" => "triage_incomplete" }.merge(period) }

    it "entra quem abandonou (tempo ou cancelamento) no período e não concluiu outra depois" do
      timed_out = person!.tap { |c| CampaignHistory.triage!(c, status: "aborted_by_timeout", at: first_instant) }
      cancelled = person!.tap { |c| CampaignHistory.triage!(c, status: "aborted_by_cancellation", at: last_instant) }
      completed_before = person!.tap do |c|
        CampaignHistory.triage!(c, at: inside - 1.day)
        CampaignHistory.triage!(c, status: "aborted_by_timeout", at: inside)
      end
      person!.tap do |c|
        CampaignHistory.triage!(c, status: "aborted_by_timeout", at: inside)
        CampaignHistory.triage!(c, at: inside + 1.day)
      end
      person!.tap { |c| CampaignHistory.triage!(c, status: "aborted_by_timeout", at: first_instant - 1.second) }
      person!.tap { |c| CampaignHistory.triage!(c, status: "aborted_by_cancellation", at: last_instant + 1.second) }
      person!.tap { |c| CampaignHistory.triage!(c, status: "aborted_by_revocation", at: inside) }
      expect(ids(described_class, params)).to contain_exactly(timed_out.id, cancelled.id, completed_before.id)
    end

    it "triagem sem cidadão não conta" do
      conversation = Conversation.create!(phone: "+5541911110001", state: "abandoned", created_at: inside)
      Triage.create!(conversation: conversation, protocol_definition: CampaignHistory.protocol,
                     protocol_name: StartTriage::DEFAULT_PROTOCOL_NAME, status: "aborted_by_timeout", answers: {},
                     created_at: inside)
      expect(ids(described_class, params)).to be_empty
    end
  end

  describe Campaigns::Criteria::TriagedNotAttended do
    let(:params) { { "kind" => "triaged_not_attended" }.merge(period) }

    it "entra quem concluiu triagem no período sem atendimento daquela triagem, com as duas bordas" do
      waiting = person!.tap { |c| CampaignHistory.triage!(c, at: inside) }
      on_first = person!.tap { |c| CampaignHistory.triage!(c, at: first_instant) }
      on_last = person!.tap { |c| CampaignHistory.triage!(c, at: last_instant) }
      person!.tap do |c|
        triage = CampaignHistory.triage!(c, at: inside)
        CampaignHistory.attendance!(c, outcome: "discharged", at: inside + 1.hour, unit: unit!, by: staff!, triage: triage)
      end
      person!.tap { |c| CampaignHistory.triage!(c, at: first_instant - 1.second) }
      person!.tap { |c| CampaignHistory.triage!(c, at: last_instant + 1.second) }
      person!.tap { |c| CampaignHistory.triage!(c, status: "aborted_by_timeout", at: inside) }
      expect(ids(described_class, params)).to contain_exactly(waiting.id, on_first.id, on_last.id)
    end

    it "triagem sem cidadão não conta" do
      anonymous_triage!(at: inside)
      expect(ids(described_class, params)).to be_empty
    end
  end
end
