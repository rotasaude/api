require "rails_helper"

# Módulo 32b (contrato §5 e §12 Q5; plano, Desvio 5): os horários do
# aprazamento, calculados na leitura. Itens sem gravar nada: o serviço só lê
# os atributos do item.
RSpec.describe Urgency::Schedule do
  let(:day) { Time.zone.local(2026, 11, 10) }
  let(:now) { day.change(hour: 9) }

  def item(kind, first: day.change(hour: 8), **attrs) = UrgencyPrescriptionItem.new(frequency_kind: kind, first_dose_at: first, **attrs)

  describe ".slots" do
    it "interval de 6 h com a 1ª dose às 08:00 e agora 09:00 → 08, 14, 20, 02 e 08 do dia seguinte" do
      expect(described_class.slots(item("interval", interval_hours: 6), now: now))
        .to eq([ day.change(hour: 8), day.change(hour: 14), day.change(hour: 20), (day + 1.day).change(hour: 2), (day + 1.day).change(hour: 8) ])
    end

    it "1ª dose no futuro: só ela e as seguintes até agora + 24 h; horários com segundos zerados" do
      slots = described_class.slots(item("interval", interval_hours: 8, first: now + 2.hours), now: now)
      expect(slots).to eq([ now + 2.hours, now + 10.hours, now + 18.hours ])
      expect(slots.map(&:sec).uniq).to eq([ 0 ])
    end

    it "agora + 24 h exato entra; um minuto depois não" do
      expect(described_class.slots(item("interval", interval_hours: 12, first: now + 24.hours), now: now)).to eq([ now + 24.hours ])
      expect(described_class.slots(item("interval", interval_hours: 12, first: now + 24.hours + 1.minute), now: now)).to eq([])
    end

    it "once → um horário, o da 1ª dose" do
      expect(described_class.slots(item("once"), now: now)).to eq([ day.change(hour: 8) ])
    end

    it "if_needed → sem horários" do
      expect(described_class.slots(item("if_needed", max_per_day: 3), now: now)).to eq([])
    end
  end

  describe ".slot?" do
    let(:interval) { item("interval", interval_hours: 6) }

    it "igualdade exata com um dos horários" do
      expect(described_class.slot?(interval, day.change(hour: 14), now: now)).to be(true)
      expect(described_class.slot?(interval, day.change(hour: 14, min: 1), now: now)).to be(false)
      expect(described_class.slot?(interval, day.change(hour: 2), now: now)).to be(false)
      expect(described_class.slot?(interval, (day + 1.day).change(hour: 14), now: now)).to be(false)
    end

    it "once e if_needed" do
      expect(described_class.slot?(item("once"), day.change(hour: 8), now: now)).to be(true)
      expect(described_class.slot?(item("once"), day.change(hour: 9), now: now)).to be(false)
      expect(described_class.slot?(item("if_needed", max_per_day: 2), day.change(hour: 8), now: now)).to be(false)
    end
  end
end
