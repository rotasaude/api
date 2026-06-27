require "rails_helper"

# Period#series agrupa por bucket no fuso America/Sao_Paulo. As colunas datetime
# são `timestamp without time zone` armazenadas em UTC (convenção do Rails), então
# a conversão UTC->local precisa acontecer ANTES do date_trunc. Estes specs fixam
# a colocação por bucket, incluindo as bordas de dia/hora no fuso de SP, e cobrem
# todos os sparklines do Admin Console (não só Cidades).
#
# Usa UnknownChannel por ser um model simples, sem associações nem RLS, com uma
# coluna datetime livre (last_seen_at) que podemos agrupar.
RSpec.describe Admin::Api::Period do
  include ActiveSupport::Testing::TimeHelpers

  let(:tz) { ActiveSupport::TimeZone["America/Sao_Paulo"] }

  def seen_at(time)
    UnknownChannel.create!(
      phone_number_id: SecureRandom.hex(8),
      first_seen_at: time,
      last_seen_at: time
    )
  end

  def series_for(key)
    Admin::Api::Period
      .parse(key: key, from: nil, to: nil, tz: tz)
      .series(UnknownChannel.all, :last_seen_at)
  end

  describe "#series colocação por dia na borda do fuso de SP" do
    # Buckets do 7d a partir de "agora" = Jun 25 12:00 SP → Jun 19..Jun 25 (7 dias).
    around { |ex| travel_to(tz.local(2026, 6, 25, 12, 0, 0)) { ex.run } }

    it "coloca o registro pelo dia local (SP), não pelo dia em UTC" do
      # 23:00 de 23/jun em SP == 02:00 de 24/jun em UTC. Pertence ao bucket de 23/jun.
      seen_at(tz.local(2026, 6, 23, 23, 0, 0))

      spark = series_for("7d")
      expect(spark.sum).to eq(1)
      expect(spark).to eq([ 0, 0, 0, 0, 1, 0, 0 ]) # índice 4 == 23/jun
    end

    it "separa registros que cruzam a meia-noite local em buckets adjacentes" do
      seen_at(tz.local(2026, 6, 23, 23, 30, 0)) # 23/jun local
      seen_at(tz.local(2026, 6, 24, 0, 30, 0))  # 24/jun local

      spark = series_for("7d")
      expect(spark.sum).to eq(2)
      expect(spark[4]).to eq(1) # 23/jun
      expect(spark[5]).to eq(1) # 24/jun
    end

    it "soma ao total de registros dentro da janela" do
      3.times { seen_at(tz.local(2026, 6, 22, 10, 0, 0)) }
      2.times { seen_at(tz.local(2026, 6, 24, 9, 0, 0)) }

      expect(series_for("7d").sum).to eq(5)
    end
  end

  describe "#series buckets por hora (today) no fuso de SP" do
    around { |ex| travel_to(tz.local(2026, 6, 25, 12, 0, 0)) { ex.run } }

    it "coloca o registro no bucket da hora local" do
      # 09:00 SP == 12:00 UTC. Bucket de hora índice 9 do dia local.
      seen_at(tz.local(2026, 6, 25, 9, 0, 0))

      spark = series_for("today")
      expect(spark.length).to eq(24)
      expect(spark.sum).to eq(1)
      expect(spark[9]).to eq(1)
    end
  end
end
