require "rails_helper"

# Módulo 31 (Desvio 1; contrato §5, P13, P61, P62): noites = cada data local D
# com início ≤ D < fim (meio-aberto; entrada e saída no mesmo dia = 0 noite); a
# aberta vai até max(expected_end_at, a noite de hoje); limite por modalidade numa janela de
# `window_days`, contando as noites do paciente em qualquer CAPS. Relógio fixo.
RSpec.describe Psychosocial::NightLimit do
  include ActiveSupport::Testing::TimeHelpers

  around { |example| travel_to(Time.zone.local(2026, 11, 25, 15, 0)) { example.run } }

  let!(:city) { psychosocial_city! }
  let(:settings) { Psychosocial::Settings.current }
  let(:caps) { caps!(modality: "caps_ad_iii") }
  let(:patient) { caps_patient! }

  def at(day, hour, month: 11) = Time.zone.local(2026, month, day, hour)
  def nov(*days) = days.map { |d| Date.new(2026, 11, d) }

  # Permanência gravada direto (o caminho real é StartNightStay/CloseNightStay).
  def stay!(from, to, open: false, unit: caps, label: "L#{SecureRandom.hex(2)}")
    staff = caps_staff!(unit)
    enrollment = PsychosocialEnrollment.find_by(patient: patient, health_unit: unit) ||
                 enrollment!(unit, patient: patient, reference: staff, started_on: Date.new(2026, 10, 1))
    attrs = { psychosocial_bed: bed!(unit, label: label), health_unit: unit, psychosocial_enrollment: enrollment, patient: patient,
              started_at: from, expected_end_at: to, started_by_user: staff }
    attrs.merge!(ended_at: to, end_reason: "Alta do acolhimento noturno", closed_by_user: staff) unless open
    PsychosocialNightStay.create!(attrs)
  end

  describe ".nights" do
    it "cada data local D com início ≤ D < fim (meio-aberto)" do
      expect(described_class.nights(at(4, 19)..at(5, 8))).to eq(nov(4))
      expect(described_class.nights(at(4, 19)..at(7, 8))).to eq(nov(4, 5, 6))
      # 23:30 de 30/11 local é 02:30 UTC de 01/12: a noite é a de 30/11.
      expect(described_class.nights(Time.zone.local(2026, 11, 30, 23, 30)..at(2, 8, month: 12)))
        .to eq([ Date.new(2026, 11, 30), Date.new(2026, 12, 1) ])
    end

    it "P61: 21:00 de D até 08:00 de D+1 = 1 noite; entrada e saída no mesmo dia = 0 noite" do
      expect(described_class.nights(at(4, 21)..at(5, 8))).to eq(nov(4))
      expect(described_class.nights(Time.zone.local(2026, 11, 4, 9, 19)..Time.zone.local(2026, 11, 4, 9, 20))).to eq([])
      expect(described_class.nights(at(4, 19)..at(4, 23))).to eq([])
      expect(described_class.nights(at(4, 0)..Time.zone.local(2026, 11, 4, 23, 59))).to eq([])
    end

    it "da encerrada: fim = ended_at (as noites reais)" do
      expect(described_class.nights(stay!(at(1, 19), at(3, 8)))).to eq(nov(1, 2))
      expect(described_class.nights(stay!(Time.zone.local(2026, 11, 16, 9, 19), Time.zone.local(2026, 11, 16, 9, 20)))).to eq([])
    end

    # P62: a aberta vai até max(expected_end_at, a noite de hoje) — hoje é 25/11.
    it "P62: aberta dentro do previsto conta até expected_end_at" do
      expect(described_class.nights(stay!(at(24, 19), at(27, 8), open: true))).to eq(nov(24, 25, 26))
    end

    it "P62: aberta além do previsto conta até hoje, com a noite de hoje" do
      stay = stay!(at(10, 19), at(12, 8), open: true)
      expect(described_class.nights(stay)).to eq(nov(*(10..25)))
      expect(described_class.effective_end(stay)).to eq(Date.new(2026, 11, 26).in_time_zone)
      # A data de corte é parâmetro (o painel corta no fim do mês ou hoje).
      expect(described_class.nights(stay, today: Date.new(2026, 11, 20))).to eq(nov(*(10..20)))
    end

    it "P62: aberta que entrou hoje, com saída prevista hoje, já conta a noite de hoje" do
      expect(described_class.nights(stay!(at(25, 9), at(25, 18), open: true))).to eq(nov(25))
    end
  end

  describe ".check" do
    it "AD III: 14 noites em 30; a 15ª passa do limite" do
      allow(described_class).to receive(:existing_nights).and_return((1..14).map { |d| Date.new(2026, 11, d) })
      expect(described_class.check(patient_id: patient.id, modality: "caps_ad_iii", new_nights: nov(20), settings: settings))
        .to eq(used: 15, limit: 14, window_days: 30, rule: "total")
    end

    it "AD III: 14 na janela passa; fora da janela não conta" do
      allow(described_class).to receive(:existing_nights).and_return((1..13).map { |d| Date.new(2026, 11, d) })
      expect(described_class.check(patient_id: patient.id, modality: "caps_ad_iii", new_nights: nov(20), settings: settings)).to be_nil
    end

    it "CAPS III: 7 corridas ou 10 intercaladas" do
      run = (1..7).map { |d| Date.new(2026, 11, d) }
      expect(described_class.check(patient_id: patient.id, modality: "caps_iii", new_nights: run, settings: settings)).to be_nil
      expect(described_class.check(patient_id: patient.id, modality: "caps_iii", new_nights: run + nov(8), settings: settings))
        .to eq(used: 8, limit: 7, window_days: 30, rule: "consecutive")

      alternate = nov(1, 3, 5, 7, 9, 11, 13, 15, 17, 19)
      expect(described_class.check(patient_id: patient.id, modality: "caps_iii", new_nights: alternate, settings: settings)).to be_nil
      expect(described_class.check(patient_id: patient.id, modality: "caps_iii", new_nights: alternate + nov(21), settings: settings))
        .to eq(used: 11, limit: 10, window_days: 30, rule: "alternate")
    end

    it "lê as permanências do paciente em qualquer CAPS (abertas até expected_end_at), sem a própria" do
      other_caps = caps!(modality: "caps_iii")
      stay!(at(2, 19), at(8, 8))                                   # 2..7 (6) no AD III
      stay!(at(10, 19), at(16, 8), unit: other_caps)               # 10..15 (6) no CAPS III
      own = stay!(at(24, 19), at(26, 8), open: true)               # 24, 25 (2), aberta
      expect(described_class.existing_nights(patient.id, Date.new(2026, 10, 27)..Date.new(2026, 11, 25), nil))
        .to eq(nov(2, 3, 4, 5, 6, 7, 10, 11, 12, 13, 14, 15, 24, 25))
      expect(described_class.existing_nights(patient.id, Date.new(2026, 11, 5)..Date.new(2026, 11, 25), own.id))
        .to eq(nov(5, 6, 7, 10, 11, 12, 13, 14, 15))

      # 14 noites + 1 nova; a própria permanência (24, 25) não conta duas vezes.
      expect(described_class.check(patient_id: patient.id, modality: "caps_ad_iii", new_nights: nov(23), settings: settings))
        .to eq(used: 15, limit: 14, window_days: 30, rule: "total")
      expect(described_class.check(patient_id: patient.id, modality: "caps_ad_iii", new_nights: nov(24, 25), settings: settings,
                                   except_stay_id: own.id)).to be_nil
    end

    it "a janela que contém uma noite nova pode terminar depois dela (entrada retroativa)" do
      allow(described_class).to receive(:existing_nights).and_return((11..24).map { |d| Date.new(2026, 11, d) })
      expect(described_class.check(patient_id: patient.id, modality: "caps_ad_iii", new_nights: nov(2), settings: settings))
        .to eq(used: 15, limit: 14, window_days: 30, rule: "total")
    end

    it "P61: o limite da janela segue com a regra nova — a permanência sem noite não consome o limite" do
      stay!(at(1, 19), at(14, 8))                                                     # 1..13 (13)
      stay!(Time.zone.local(2026, 11, 15, 9, 19), Time.zone.local(2026, 11, 15, 9, 20)) # 0
      expect(described_class.check(patient_id: patient.id, modality: "caps_ad_iii", new_nights: nov(20), settings: settings)).to be_nil
      expect(described_class.check(patient_id: patient.id, modality: "caps_ad_iii", new_nights: nov(20, 21), settings: settings))
        .to eq(used: 15, limit: 14, window_days: 30, rule: "total")
      expect(described_class.check(patient_id: patient.id, modality: "caps_ad_iii", new_nights: [], settings: settings)).to be_nil
    end

    it "modalidade sem limite configurado nunca passa" do
      expect(described_class.check(patient_id: patient.id, modality: "caps_ii", new_nights: (1..30).map { |d| Date.new(2026, 11, d) },
                                   settings: settings)).to be_nil
    end
  end

  describe ".used" do
    it "as noites na janela que termina na data e o limite (total no AD, alternadas no CAPS III)" do
      stay!(at(1, 19), at(4, 8))
      stay!(at(20, 19), at(28, 8), open: true)
      expect(described_class.used(patient_id: patient.id, modality: "caps_ad_iii", date: Date.new(2026, 11, 22), settings: settings))
        .to eq(used: 6, limit: 14)
      expect(described_class.used(patient_id: patient.id, modality: "caps_iii", date: Date.new(2026, 11, 22), settings: settings))
        .to eq(used: 6, limit: 10)
      expect(described_class.used(patient_id: patient.id, modality: "caps_ii", date: Date.new(2026, 11, 22), settings: settings)).to be_nil
    end

    it "P61: a permanência sem noite (mesmo dia) não conta" do
      stay!(Time.zone.local(2026, 11, 21, 9, 19), Time.zone.local(2026, 11, 21, 9, 20))
      stay!(at(22, 21), at(27, 8), open: true) # 22..26; a janela termina em 25
      expect(described_class.used(patient_id: patient.id, modality: "caps_ad_iii", date: Date.new(2026, 11, 25), settings: settings))
        .to eq(used: 4, limit: 14)
    end

    it "P62: a aberta vencida há muito conta até hoje, mesmo com o previsto antes da janela" do
      # Previsto em 03/10, antes da janela (27/10..25/11); aberta até hoje: a janela inteira.
      stay!(at(1, 19, month: 10), at(3, 8, month: 10), open: true)
      expect(described_class.used(patient_id: patient.id, modality: "caps_ad_iii", date: Date.new(2026, 11, 25), settings: settings))
        .to eq(used: 30, limit: 14)
    end
  end
end
