require "rails_helper"

RSpec.describe Admin::ConversationsQuery do
  def period = Admin::Api::Period.parse(key: "7d", from: nil, to: nil, tz: ActiveSupport::TimeZone["America/Sao_Paulo"])

  def definition
    {
      "name" => "resp", "version" => 1, "start_step_id" => "s1",
      "steps" => [
        { "id" => "s1", "prompt" => "?", "answer_type" => "boolean",
          "branches" => { "true" => nil, "false" => nil }, "weights" => { "true" => 1, "false" => 0 } }
      ],
      "scoring" => { "type" => "weighted", "thresholds" => { "baixa" => 0 }, "priority_map" => { "baixa" => 9 } }
    }
  end

  # Regressão: avg_complete_minutes faz pluck sobre triages ⋈ conversations, e
  # ambas têm created_at. Sem qualificar a coluna, o Postgres levanta
  # PG::AmbiguousColumn e o painel Conversas 500a assim que há ≥1 triagem
  # completa no período. Este teste exercita esse caminho.
  it "computes avgToCompleteMin over a completed triage without an ambiguous-column error" do
    prot = ProtocolDefinition.create!(name: "resp", version: 1, status: "active", definition: definition)
    conv = Conversation.create!(phone: "+5511999", state: "consented")
    Triage.create!(conversation_id: conv.id, protocol_definition_id: prot.id,
                   protocol_name: "resp", status: "completed",
                   created_at: 20.minutes.ago, completed_at: 10.minutes.ago)

    out = Admin::ConversationsQuery.call(period: period)

    expect(out[:avgToCompleteMin]).to be_a(Numeric)
    expect(out[:avgToCompleteMin]).to be_within(0.5).of(10.0)
  end

  it "returns nil avgToCompleteMin when there are no completed triages" do
    Conversation.create!(phone: "+5511888", state: "greeting")

    out = Admin::ConversationsQuery.call(period: period)

    expect(out[:avgToCompleteMin]).to be_nil
    expect(out[:funnel].find { |f| f[:key] == "greeting" }[:count]).to eq(1)
  end

  # F-02.9: o funil mostra os estados ativos e as saídas mostram TODOS os
  # desfechos terminais; a web (único canal do cidadão desde o ADR 0017) conta.
  describe "distribuição por estado (F-02.9)" do
    let(:citizen) { Citizen.create!(cpf: "52998224725", phone: "+5541998765432") }

    def conversation!(state, channel: "web")
      attrs = { phone: citizen.phone, state: state, channel: channel }
      attrs[:citizen] = citizen if channel == "web"
      Conversation.create!(attrs)
    end

    it "counts every terminal state as an exit, web conversations included" do
      %w[completed completed abandoned declined cancelled revoked].each { |s| conversation!(s) }
      conversation!("consented")

      out = Admin::ConversationsQuery.call(period: period)

      exits = out[:exits].to_h { |e| [ e[:key], e[:count] ] }
      expect(exits).to eq("completed" => 2, "abandoned" => 1, "declined" => 1, "cancelled" => 1, "revoked" => 1)
      expect(out[:funnel].find { |f| f[:key] == "consented" }[:count]).to eq(1)
    end

    it "computes abandonRate as abandoned over conversations started in the period, in percent" do
      %w[abandoned completed completed consented].each { |s| conversation!(s) }

      expect(Admin::ConversationsQuery.call(period: period)[:abandonRate]).to eq(25.0)
    end

    it "returns nil abandonRate when no conversation started in the period" do
      expect(Admin::ConversationsQuery.call(period: period)[:abandonRate]).to be_nil
    end

    it "leaves conversations started before the period out of the distribution" do
      conversation!("abandoned").update_columns(created_at: 30.days.ago)

      out = Admin::ConversationsQuery.call(period: period)

      expect(out[:exits].sum { |e| e[:count] }).to eq(0)
      expect(out[:abandonRate]).to be_nil
    end
  end
end
