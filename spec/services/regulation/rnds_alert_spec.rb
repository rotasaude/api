require "rails_helper"

# Módulo 26c, Task 13 (Q11): o alarme D-1 da regulação -> RNDS. Prazo = as
# 23:00 do dia seguinte ao `enqueued_at`, no fuso da CIDADE (nascida com ele:
# o fuso é imutável); linha da carga inicial ganha 72 h. Roda em três fusos
# para pegar "hoje" calculado num fuso fixo (lição do 27b).
RSpec.describe Regulation::RndsAlert, type: :model do
  include ActiveSupport::Testing::TimeHelpers

  %w[America/Sao_Paulo America/Manaus America/Noronha].each do |zone_name|
    context "no fuso #{zone_name}" do
      around { |example| Time.use_zone(zone_name) { example.run } }

      before do
        City.create!(slug: TEST_CITY_A.slug, name: TEST_CITY_A.name, status: "active", time_zone: zone_name,
                     database_url: TEST_CITY_A.database_url, encryption_key: TEST_CITY_A.encryption_key,
                     schema_version: CitySchema.expected_version.to_s)
        regulation_city!
      end

      def at(day, hour, min = 0) = Time.zone.local(2026, 11, day, hour, min)

      def sync!(status: "queued", enqueued_at: at(10, 10), **over)
        RegulationRndsSync.create!({ regulation_request: regulation_request!, status: status, enqueued_at: enqueued_at }.merge(over))
      end

      def late?(sync, now) = described_class.late?(sync, now: now)

      def late_count(now) = described_class.counts(now: now)[:late]

      it "usa o fuso da cidade" do
        expect(Time.zone.name).to eq(zone_name)
        expect(City.find_by!(slug: TEST_CITY_A.slug).time_zone).to eq(zone_name)
      end

      it "mudança às 10:00 de D: não atrasa às 22:59 de D+1; atrasa às 23:00 de D+1" do
        row = sync!(enqueued_at: at(10, 10))
        expect(late?(row, at(11, 22, 59))).to be(false)
        expect(late?(row, at(11, 23))).to be(true)
        expect(late_count(at(11, 22, 59))).to eq(0)
        expect(late_count(at(11, 23))).to eq(1)
      end

      it "vira o dia pelo fuso da cidade (mudança às 23:30 de D tem até 23:00 de D+1)" do
        row = sync!(enqueued_at: at(10, 23, 30))
        expect(late?(row, at(11, 22, 59))).to be(false)
        expect(late?(row, at(11, 23))).to be(true)
        expect(late_count(at(11, 22, 59))).to eq(0)
        expect(late_count(at(11, 23))).to eq(1)
      end

      it "mudança logo depois da meia-noite local conta no dia local" do
        row = sync!(enqueued_at: at(10, 0, 5))
        expect(late?(row, at(11, 22, 59))).to be(false)
        expect(late?(row, at(11, 23))).to be(true)
        expect(late_count(at(11, 23))).to eq(1)
      end

      it "blocked, rejected, failed, sending e queued também atrasam" do
        %w[queued sending blocked rejected failed].each { |status| sync!(status: status) }
        expect(late_count(at(11, 23))).to eq(5)
      end

      it "idle nunca atrasa" do
        row = sync!(status: "idle", last_rnds_id: "RA1")
        expect(late?(row, at(20, 12))).to be(false)
        expect(late_count(at(20, 12))).to eq(0)
      end

      it "excluded e erased ficam fora" do
        excluded = sync!(status: "excluded")
        erased = sync!(status: "erased")
        expect([ excluded, erased ].map { |row| late?(row, at(20, 12)) }).to eq([ false, false ])
        expect(late_count(at(20, 12))).to eq(0)
      end

      it "carga inicial criada há 71 h fica fora; há 73 h, dentro" do
        now = at(15, 12)
        fresh = sync!(initial_load: true, enqueued_at: now - 71.hours, created_at: now - 71.hours)
        old = sync!(initial_load: true, enqueued_at: now - 73.hours, created_at: now - 73.hours)
        expect(late?(fresh, now)).to be(false)
        expect(late?(old, now)).to be(true)
        expect(late_count(now)).to eq(1)
      end

      # Final wave, item 6: a fronteira das 72 h é a mesma no late? e no SQL (fora só ANTES de completar 72 h).
      it "carga inicial com exatamente 72 h → atrasa, no late? e na contagem" do
        now = at(15, 12)
        row = sync!(initial_load: true, enqueued_at: now - 72.hours, created_at: now - 72.hours)
        expect(late?(row, now)).to be(true)
        expect(late_count(now)).to eq(1)
      end

      it "late? casa com a contagem SQL linha a linha" do
        now = at(15, 12)
        offsets = [ 72.hours - 1.second, 72.hours, 73.hours, 20.hours ]
        rows = %w[queued idle erased].product([ true, false ], offsets).map do |status, initial, offset|
          sync!(status: status, initial_load: initial, enqueued_at: now - offset, created_at: now - offset)
        end
        rows.each do |row|
          sql = described_class.counts(RegulationRndsSync.where(id: row.id), now: now)[:late] == 1
          expect(late?(row, now)).to eq(sql), "#{row.status} initial_load=#{row.initial_load} created_at=#{row.created_at}"
        end
        expect(rows.count { |row| late?(row, now) }).to eq(late_count(now))
        expect(late_count(now)).to be_positive
      end

      # Q26: a linha reenfileirada por ajuste entra na faixa da carga inicial com a carência a contar do reenfileiramento.
      it "faixa da carga inicial com created_at antigo: a carência conta do enqueued_at" do
        now = at(15, 12)
        fresh = sync!(initial_load: true, enqueued_at: now - 71.hours, created_at: now - 60.days)
        old = sync!(initial_load: true, enqueued_at: now - 73.hours, created_at: now - 60.days)
        expect([ late?(fresh, now), late?(old, now) ]).to eq([ false, true ])
        expect(late_count(now)).to eq(1)
      end

      it "linha comum não ganha a carência da carga inicial" do
        now = at(15, 12)
        sync!(initial_load: false, enqueued_at: now - 71.hours, created_at: now - 71.hours)
        expect(late_count(now)).to eq(1)
      end

      it "conta por status (queued inclui sending; accepted = idle com last_rnds_id)" do
        now = at(10, 12)
        sync!(status: "queued")
        sync!(status: "sending")
        sync!(status: "blocked")
        sync!(status: "rejected")
        sync!(status: "failed")
        sync!(status: "idle", last_rnds_id: "RA1")
        sync!(status: "idle")
        sync!(status: "excluded", last_rnds_id: "RA2")
        expect(described_class.counts(now: now)).to eq(queued: 2, blocked: 1, rejected: 1, failed: 1, late: 0, accepted: 1)
      end

      it "respeita o escopo recebido" do
        mine = sync!(status: "failed")
        sync!(status: "failed")
        scope = RegulationRndsSync.where(id: mine.id)
        expect(described_class.counts(scope, now: at(20, 12))).to include(failed: 1, late: 1)
      end
    end
  end
end
