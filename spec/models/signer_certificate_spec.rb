require "rails_helper"

# Contrato §13: expires_in_days = dias inteiros de calendário no fuso da
# cidade, negativo depois do vencimento.
RSpec.describe SignerCertificate do
  def days(not_after, now, zone: "America/Sao_Paulo")
    Time.use_zone(zone) { described_class.new(not_after: Time.zone.parse(not_after)).expires_in_days(Time.zone.parse(now)) }
  end

  it "conta dias de calendário, não blocos de 24 h (perto da meia-noite)" do
    expect(days("2026-10-10 08:00", "2026-10-09 20:00")).to eq(1)
    expect(days("2026-10-09 23:00", "2026-10-09 20:00")).to eq(0)
    expect(days("2027-10-09 08:00", "2026-10-09 20:00")).to eq(365)
  end

  it "vencido no mesmo dia é -1; ontem também; depois conta para trás" do
    expect(days("2026-10-09 08:00", "2026-10-09 20:00")).to eq(-1)
    expect(days("2026-10-09 20:00", "2026-10-09 20:00")).to eq(-1)
    expect(days("2026-10-08 23:00", "2026-10-09 01:00")).to eq(-1)
    expect(days("2026-10-06 23:00", "2026-10-09 01:00")).to eq(-3)
  end

  it "usa o fuso da cidade (Time.zone)" do
    not_after = Time.utc(2026, 10, 10, 2, 30) # 23:30 do dia 9 em São Paulo
    now = Time.utc(2026, 10, 9, 22, 0)        # 19:00 do dia 9 em São Paulo
    certificate = described_class.new(not_after: not_after)
    expect(Time.use_zone("America/Sao_Paulo") { certificate.expires_in_days(now) }).to eq(0)
    expect(Time.use_zone("UTC") { certificate.expires_in_days(now) }).to eq(1)
  end
end
