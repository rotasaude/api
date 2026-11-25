require "rails_helper"

# Módulo 27b, Task 12 (contrato §3; Q16; R25): a faixa de alerta do envio,
# calculada na leitura, sem tabela. `late`: a remessa de ontem não `finished`
# depois das 15:00 de hoje no fuso da cidade (e a que nem nasceu, com domínio
# devido); `lost`: registros não aceitos de remessas `lost` nos últimos 30 dias;
# `rejected`: recusados de ontem (ainda reenviáveis).
RSpec.describe Bnafar::Alert, type: :model do
  include ActiveSupport::Testing::TimeHelpers

  let!(:city) { pharmacy_city! }
  let(:today) { Time.zone.today }

  def at(hour, min = 0) = today.in_time_zone.change(hour: hour, min: min)
  def alert(now, domains: []) = described_class.call(environment: "production", now: now, domains: domains)

  it "remessa de ontem processing às 14:59 → late 0; às 15:00 → 1" do
    bnafar_submission!(reference_on: today - 1, status: "processing")

    expect(alert(at(14, 59))[:late]).to eq(0)
    expect(alert(at(15))[:late]).to eq(1)
  end

  it "remessa de ontem finished nunca é atrasada; a de outro ambiente não conta" do
    bnafar_submission!(reference_on: today - 1, status: "finished")
    bnafar_submission!(reference_on: today - 1, subject: "exit", status: "queued", environment: "homologation")

    expect(alert(at(16))).to include(late: 0, last_finished_on: today - 1)
  end

  it "credencial recusada o dia todo (sem remessa de ontem, com domínio devido) → late 1 às 15:00" do
    expect(alert(at(15), domains: [ Stock::Domain::MEDICATION ])[:late]).to eq(1)
    expect(alert(at(14, 59), domains: [ Stock::Domain::MEDICATION ])[:late]).to eq(0)
    expect(alert(at(15), domains: [])[:late]).to eq(0)
  end

  it "três perdidos há 10 dias e um há 31 → lost 3; aceito de remessa perdida não conta" do
    recent = bnafar_submission!(reference_on: today - 10, status: "lost")
    old = bnafar_submission!(reference_on: today - 31, status: "lost")
    3.times { bnafar_record!(recent, status: %w[rejected pending rejected].sample) }
    bnafar_record!(recent, status: "accepted")
    bnafar_record!(old, status: "rejected")

    expect(alert(at(10))[:lost]).to eq(3)
  end

  it "rejected = recusados de ontem; os de anteontem já não são reenviáveis" do
    yesterday = bnafar_submission!(reference_on: today - 1, status: "finished")
    older = bnafar_submission!(reference_on: today - 2, status: "finished")
    2.times { bnafar_record!(yesterday, status: "rejected", error_codes: [ "MSG12" ]) }
    bnafar_record!(yesterday, status: "accepted")
    bnafar_record!(older, status: "rejected", error_codes: [ "MSG12" ])

    expect(alert(at(10))[:rejected]).to eq(2)
  end

  it "sem remessa nenhuma: tudo zerado e last_finished_on nil" do
    expect(alert(at(16))).to eq(late: 0, lost: 0, rejected: 0, last_finished_on: nil)
  end
end
