require "rails_helper"

# api#34: os painéis ao vivo (ADR 0022) usam a MESMA definição de revogada do
# Analytics (ADR 0025): abortada por revogação, ou com o consentimento da
# própria conversa revogado (com ou sem atendimento). Revogada não entra em
# nenhum número de concluídas; aparece à parte, só como contagem do período.
RSpec.describe "Triagens revogadas nos painéis ao vivo (api#34)" do
  def period = Admin::Api::Period.parse(key: "7d", from: nil, to: nil, tz: ActiveSupport::TimeZone["America/Sao_Paulo"])

  let(:day) { Time.zone.today - 1 }
  let(:unit) { create_unit("UBS Centro") }

  let!(:normal) { a_triage!(day: day, tier: "alta", priority: 1) }
  # Revogada depois de concluir e já atendida: o anonimizador a retém (tier fica).
  let!(:revoked_with_attendance) do
    a_triage!(day: day, hour: 11, tier: "alta", priority: 1, revoked: true).tap do |t|
      an_attendance!(triage: t, unit: unit)
      t.update_columns(completed_at: t.created_at + 60.minutes)
    end
  end
  # Revogada depois de concluir, sem atendimento: o anonimizador limpa o tier.
  let!(:revoked_without_attendance) do
    a_triage!(day: day, hour: 12, tier: "baixa", priority: 9, revoked: true).tap do |t|
      t.update_columns(completed_at: t.created_at + 60.minutes)
      Triages::Anonymize.call(t)
    end
  end
  let!(:aborted) { a_triage!(day: day, hour: 13, status: "aborted_by_revocation") }

  describe "definição compartilhada" do
    it "Triage.revoked marca exatamente as mesmas triagens que o Analytics" do
      analytics = ApplicationRecord.connection.select_values(
        "SELECT t.id #{Analytics::Consolidate::Base::TRIAGES} WHERE #{Analytics::Consolidate::Base::REVOCATION}"
      )

      expect(Triage.revoked.ids).to contain_exactly(revoked_with_attendance.id, revoked_without_attendance.id, aborted.id)
      expect(Triage.revoked.ids).to match_array(analytics)
      expect(Triage.not_revoked.ids).to contain_exactly(normal.id)
    end

    def revoked_on_both_sides?(triage)
      analytics = ApplicationRecord.connection.select_value(ApplicationRecord.sanitize_sql_array([
        "SELECT #{Analytics::Consolidate::Base::REVOCATION} #{Analytics::Consolidate::Base::TRIAGES} WHERE t.id = ?",
        triage.id
      ]))
      [ Triage.revoked.exists?(id: triage.id), !Triage.not_revoked.exists?(id: triage.id), analytics ]
    end

    def bare_triage!(conversation, status:)
      protocol = ProtocolDefinition.find_by(name: StartTriage::DEFAULT_PROTOCOL_NAME, status: "active") ||
                 create_default_protocol!
      completed = status == "completed"
      Triage.create!(conversation: conversation, protocol_definition: protocol, protocol_name: protocol.name,
                     status: status, tier: completed ? "alta" : nil, priority: completed ? 1 : nil, answers: {},
                     created_at: 2.hours.ago, completed_at: 1.hour.ago)
    end

    it "abortada por revogação conta como revogada mesmo com o consentimento da conversa ativo, nos dois lados" do
      conversation = Conversation.create!(phone: "+5541977770001", state: "consented")
      Consent.create!(conversation: conversation, version: 1, policy_text_sha: "sha", channel: "web", given_at: 3.hours.ago)
      triage = bare_triage!(conversation, status: "aborted_by_revocation")

      expect(revoked_on_both_sides?(triage)).to eq([ true, true, true ])
    end

    it "só a conversa da própria triagem conta: outra conversa revogada do mesmo cidadão não, nos dois lados" do
      citizen = analytics_citizen!
      other = Conversation.create!(channel: "web", citizen: citizen, phone: citizen.phone, state: "revoked")
      Consent.create!(conversation: other, version: 1, policy_text_sha: "sha", channel: "web",
                      given_at: 5.hours.ago, revoked_at: 4.hours.ago)
      own = Conversation.create!(channel: "web", citizen: citizen, phone: citizen.phone, state: "completed")
      Consent.create!(conversation: own, version: 1, policy_text_sha: "sha", channel: "web", given_at: 3.hours.ago)
      triage = bare_triage!(own, status: "completed")

      expect(revoked_on_both_sides?(triage)).to eq([ false, false, false ])
    end
  end

  describe Admin::OverviewQuery do
    let(:out) { described_class.call(period: period) }
    def kpi(id) = out[:kpis].find { |k| k[:id] == id }

    it "conta só a concluída não revogada em concluídas, urgentes e na taxa" do
      expect(kpi("done")[:value]).to eq(1)
      expect(kpi("done")[:spark].sum).to eq(1)
      expect(kpi("urgent")[:value]).to eq(1)
      expect(kpi("urgent")[:spark].sum).to eq(1)
      expect(kpi("completion")[:value]).to eq(25.0)
    end

    it "mostra as revogadas do período à parte, só como contagem" do
      expect(out[:revoked]).to eq(3)
    end
  end

  describe Admin::ClassificationQuery do
    let(:out) { described_class.call(period: period) }

    it "deixa a revogada fora dos tiers, da urgência, dos pivôs e da amostra" do
      expect(out[:tiers].map { |t| [ t[:key], t[:count] ] }).to eq([ [ "alta", 1 ] ])
      expect(out[:urgent]).to eq(1)
      expect(out[:urgentTrend].sum).to eq(1)
      expect(out[:byProtocol].sum { |row| row[:counts].values.sum }).to eq(1)
      expect(out[:byMode].sum { |row| row[:count] }).to eq(1)
      expect(out[:sampleTriages].map { |row| row[:id] }).to eq([ normal.id ])
    end

    it "mostra as revogadas do período à parte, só como contagem" do
      expect(out[:revoked]).to eq(3)
    end
  end

  describe Admin::TriagesQuery do
    let(:out) { described_class.call(period: period) }

    it "conta só a concluída não revogada em concluídas e na taxa; iniciadas seguem todas" do
      expect(out[:started]).to eq(4)
      expect(out[:completed]).to eq(1)
      expect(out[:completionRate]).to eq(25.0)
    end

    it "mostra as revogadas do período à parte, só como contagem" do
      expect(out[:revoked]).to eq(3)
    end
  end

  describe Admin::ConversationsQuery do
    it "calcula o tempo até concluir só sobre a concluída não revogada" do
      expect(described_class.call(period: period)[:avgToCompleteMin]).to eq(6.0)
    end
  end

  describe "com filtro de bairro (ADR 0023)" do
    let(:batel) { Neighborhood.create!(name: "Batel", source: "seed") }
    let(:centro) { Neighborhood.create!(name: "Centro", source: "seed") }
    let(:suppressed) { Admin::SmallCount::SUPPRESSED }

    before do
      2.times { |i| a_triage!(day: day, hour: 14, minute: i, neighborhood: batel, revoked: true) }
      5.times { |i| a_triage!(day: day, hour: 15, minute: i, neighborhood: centro, revoked: true) }
    end

    it "com o filtro ligado, os três painéis não devolvem a contagem de revogadas (null)" do
      # A revogada anonimizada perde o bairro: a contagem filtrada enganaria,
      # e em Triagens sairia por subtração de iniciadas e concluídas.
      [ Admin::OverviewQuery, Admin::ClassificationQuery, Admin::TriagesQuery ].each do |query|
        [ batel.id, centro.id, "none" ].each do |raw|
          out = query.call(period: period, filter: Admin::NeighborhoodFilter.parse(raw))
          expect(out).to have_key(:revoked)
          expect(out[:revoked]).to be_nil, "#{query} com filtro #{raw} devolveu #{out[:revoked].inspect}"
        end
        expect(query.call(period: period)[:revoked]).to eq(10)
      end
    end
  end
end
