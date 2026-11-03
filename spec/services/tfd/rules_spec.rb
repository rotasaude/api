require "rails_helper"

# Módulo 30, Task 9 (ADR 0048; plano, Desvio 11): as recusas do envio e da
# autorização do TFD, todas de uma vez. Processo em memória (TfdCase.new): a
# regra só lê o destino, o laudo e o atendimento.
RSpec.describe Tfd::Rules do
  before { transport_city!(tfd: true) }

  let(:report) { TransportHelpers::TFD_REPORT.dup }

  def tfd(km: 380, metropolitan: false, report: self.report, appointment_at: nil)
    TfdCase.new(transport_destination: TransportDestination.new(distance_km: km, metropolitan: metropolitan), report: report,
                appointment_at: appointment_at)
  end

  def errors(tfd_case, stage: :submit, **opts)
    described_class.problems(tfd_case, settings: TransportSetting.current, stage: stage, **opts).map { |p| p[:error] }
  end

  it "distância: 49 km com limite 50 recusa; 50 km passa; com o limite da cidade em 60, 55 km recusa" do
    expect(errors(tfd(km: 49))).to eq([ "distance_below_minimum" ])
    expect(errors(tfd(km: 50))).to eq([])
    TransportSetting.current.update!(tfd_min_distance_km: 60)
    expect(errors(tfd(km: 55))).to eq([ "distance_below_minimum" ])
    expect(errors(tfd(km: 60))).to eq([])
  end

  it "destino metropolitano recusa mesmo longe" do
    expect(errors(tfd(km: 380, metropolitan: true))).to eq([ "metropolitan_destination" ])
  end

  it "atenção básica: grupo 01 e as consultas da APS recusam; a consulta especializada passa" do
    expect(errors(tfd(report: report.merge("sigtap_code" => "0101010010")))).to include("primary_care_procedure")
    expect(errors(tfd(report: report.merge("sigtap_code" => "0301010064")))).to eq([ "primary_care_procedure" ])
    expect(errors(tfd(report: report.merge("sigtap_code" => "0301010072")))).to eq([])
    expect(Tfd::PrimaryCare.covers?("0101010010")).to be(true)
    expect(Tfd::PrimaryCare.covers?("0301010030")).to be(true)
    expect([ Tfd::PrimaryCare.covers?("0301010072"), Tfd::PrimaryCare.covers?(nil) ]).to eq([ false, false ])
  end

  it "código fora da SIGTAP ativa (ou ausente) → invalid_sigtap_code" do
    expect(errors(tfd(report: report.merge("sigtap_code" => "0399999999")))).to eq([ "invalid_sigtap_code" ])
    expect(errors(tfd(report: report.merge("sigtap_code" => nil)))).to eq([ "invalid_sigtap_code" ])
  end

  it "sem CID → cid_required; justificativa fora de 20..2000 → justification_required; todas juntas" do
    expect(errors(tfd(report: report.merge("cid10" => nil)))).to eq([ "cid_required" ])
    expect(errors(tfd(report: report.merge("justification" => "a" * 19)))).to eq([ "justification_required" ])
    expect(errors(tfd(report: report.merge("justification" => "a" * 20)))).to eq([])
    expect(errors(tfd(report: report.merge("justification" => "a" * 2001)))).to eq([ "justification_required" ])
    all = tfd(km: 27, metropolitan: true, report: report.merge("sigtap_code" => "0301010064", "cid10" => nil, "justification" => "curta"))
    expect(errors(all)).to contain_exactly("distance_below_minimum", "metropolitan_destination", "primary_care_procedure",
                                           "cid_required", "justification_required")
  end

  it "autorização: sem appointment_at → appointment_required; com faturamento e sem unidade → billing_unit_missing" do
    expect(errors(tfd, stage: :authorize, billing_enabled: false)).to eq([ "appointment_required" ])
    expect(errors(tfd(appointment_at: 3.days.from_now), stage: :authorize, billing_enabled: false)).to eq([])
    expect(errors(tfd(appointment_at: 3.days.from_now), stage: :authorize, billing_enabled: true)).to eq([ "billing_unit_missing" ])
    expect(errors(tfd, stage: :submit)).to eq([])
  end

  it "cid10: sem ponto e em maiúsculas; vazio é nil; fora do formato é :invalid (o normalizador do faturamento)" do
    expect(described_class.cid10("n18.5")).to eq("N185")
    expect([ described_class.cid10(nil), described_class.cid10("") ]).to eq([ nil, nil ])
    expect([ described_class.cid10("185"), described_class.cid10(185) ]).to eq(%i[invalid invalid])
  end
end
