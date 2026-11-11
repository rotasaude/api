require "rails_helper"

# Módulo 33 (ADR 0051; contrato §2; Desvio 3, Q3, Q17): o prazo em SQL
# (due_on_sql / color_sql) e o espelho em Ruby dão o mesmo valor, nas
# combinações urgente × prorrogada × suspensa × aguardando complemento × final.
RSpec.describe Ombudsman::Deadlines do
  let(:today) { Date.new(2026, 11, 11) }
  let(:settings) { OmbudsmanSetting.new } # os padrões do banco: 30/30/15/20/20/20/5
  let(:started) { Time.zone.local(2026, 11, 11, 10) }

  def make(received_at: started, **attrs) = raw_manifestation!(received_at: received_at, **attrs)

  def received(days_ago) = started - days_ago.days

  describe "#due_on e #color" do
    it "recebida hoje: hoje + 30, verde" do
      m = make
      expect(described_class.due_on(m, settings, today: today)).to eq(today + 30)
      expect(described_class.color(m, settings, today: today)).to eq("green")
    end

    it "urgente: + 15; prorrogada: + 30 + 30" do
      expect(described_class.due_on(make(urgent: true), settings, today: today)).to eq(today + 15)
      expect(described_class.due_on(make(extended: true, extension_reason: "Aguardando laudo."), settings, today: today)).to eq(today + 60)
    end

    it "dias suspensos entram no prazo: suspended_days 7 → + 37" do
      expect(described_class.due_on(make(suspended_days: 7), settings, today: today)).to eq(today + 37)
    end

    it "a cinco dias do fim a cor é amarela; no dia do fim ainda amarela; um dia depois, vermelha" do
      m = make(received_at: received(25)) # vence em hoje + 5
      expect(described_class.due_on(m, settings, today: today)).to eq(today + 5)
      expect(described_class.color(m, settings, today: today)).to eq("yellow")
      expect(described_class.color(m, settings, today: today + 5)).to eq("yellow")
      expect(described_class.color(m, settings, today: today + 6)).to eq("red")
      expect(described_class.color(make(received_at: received(24)), settings, today: today)).to eq("green")
    end

    it "warning_days = 1 muda a amarela" do
      one = OmbudsmanSetting.new(warning_days: 1)
      m = make(received_at: received(25))
      expect(described_class.color(m, one, today: today)).to eq("green")
      expect(described_class.color(make(received_at: received(29)), one, today: today)).to eq("yellow")
    end

    it "aguardando complemento pedido há 4 dias: paused e due_on + 34 (soma os dias do complemento em curso)" do
      m = make(state: "awaiting_complement", complement_requested_at: Time.zone.local(2026, 11, 7, 9))
      expect(described_class.color(m, settings, today: today)).to eq("paused")
      expect(described_class.due_on(m, settings, today: today)).to eq(today + 34)
    end

    it "estado final: cor nula e due_on do ciclo" do
      m = make(state: "answered", concluded_at: started)
      expect(described_class.color(m, settings, today: today)).to be_nil
      expect(described_class.due_on(m, settings, today: today)).to eq(today + 30)
    end

    it "lê sempre a configuração vigente (Q17)" do
      m = make
      expect(described_class.due_on(m, OmbudsmanSetting.new(response_days: 10), today: today)).to eq(today + 10)
    end
  end

  describe "SQL e Ruby iguais" do
    it "dão o mesmo due_on e a mesma cor em todas as combinações" do
      awaiting = Time.zone.local(2026, 11, 7, 9)
      made = [
        make,
        make(urgent: true),
        make(extended: true, extension_reason: "Aguardando laudo."),
        make(urgent: true, extended: true, extension_reason: "Aguardando laudo.", suspended_days: 3),
        make(suspended_days: 7, received_at: received(20)),
        make(received_at: received(25)),
        make(received_at: received(26)),
        make(received_at: received(45), urgent: true),
        make(state: "awaiting_complement", complement_requested_at: awaiting),
        make(state: "awaiting_complement", complement_requested_at: awaiting, suspended_days: 2, urgent: true, received_at: received(10)),
        make(state: "forwarded"),
        make(state: "answered", concluded_at: started, received_at: received(60)),
        make(state: "archived", archive_reason: "improper", concluded_at: started)
      ]
      [ settings, OmbudsmanSetting.new(warning_days: 1, response_days: 12, urgent_days: 4, extension_days: 9) ].each do |config|
        rows = OmbudsmanManifestation.where(id: made.map(&:id))
                                     .select("id, #{described_class.due_on_sql(config, today: today)} AS d, " \
                                             "#{described_class.color_sql(config, today: today)} AS c").index_by(&:id)
        made.each do |m|
          expect(rows.fetch(m.id).d).to eq(described_class.due_on(m, config, today: today))
          expect(rows.fetch(m.id).c).to eq(described_class.color(m, config, today: today))
        end
      end
    end

    it "usa o fuso da cidade na data do pedido do complemento" do
      Time.use_zone("America/Sao_Paulo") do
        # 01:00 UTC de 8/11 ainda é 7/11 em São Paulo: 4 dias até 11/11
        m = make(received_at: Time.zone.local(2026, 11, 11, 10), state: "awaiting_complement",
                 complement_requested_at: Time.utc(2026, 11, 8, 1))
        d = OmbudsmanManifestation.where(id: m.id).pick(Arel.sql(described_class.due_on_sql(settings, today: today)))
        expect(d).to eq(described_class.due_on(m, settings, today: today))
        expect(d).to eq(today + 34)
      end
    end
  end

  describe "encaminhamento e complemento" do
    it "forwarding_due_on: data + forwarding_days" do
      expect(described_class.forwarding_due_on(today, settings)).to eq(today + 20)
    end

    it "forwarding_color: pela mesma regra, só em pending" do
      due = today + 5
      pending = OmbudsmanForwarding.new(state: "pending", due_on: due)
      expect(described_class.forwarding_color(pending, settings, today: today)).to eq("yellow")
      expect(described_class.forwarding_color(pending, settings, today: today - 1)).to eq("green")
      expect(described_class.forwarding_color(pending, settings, today: due + 1)).to eq("red")
      expect(described_class.forwarding_color(OmbudsmanForwarding.new(state: "replied", due_on: due), settings, today: due + 1)).to be_nil
    end

    it "complement_due_on: dia do pedido + complement_days; nulo sem pedido" do
      m = make(state: "awaiting_complement", complement_requested_at: Time.zone.local(2026, 11, 7, 23, 30))
      expect(described_class.complement_due_on(m, settings)).to eq(Date.new(2026, 11, 27))
      expect(described_class.complement_due_on(make, settings)).to be_nil
    end
  end
end
