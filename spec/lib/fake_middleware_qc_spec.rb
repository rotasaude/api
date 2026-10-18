require "rails_helper"
require Rails.root.join("lib/fake_middleware/runner").to_s

# Spec §7 e contrato §6: o simulado manda corridas de controle — níveis 1 e
# 2 do lote CQB-2611 no BIO-01, glicose e creatinina —, uma aprovada e uma
# reprovada por 2-2s entre níveis na glicose. Log sem código de barras nem valor.
RSpec.describe "FakeMiddleware — controle", type: :request do
  let(:plan) { FakeMiddleware::QcPlan }

  before do
    city = lab_city!(fake_middleware: true)
    Platform::Features.set!(city: city, key: "lab_quality_control", enabled: true, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
    provider = lab_provider!
    instrument = qc_instrument!(provider, hl7_equipment_id: plan::INSTRUMENT)
    glucose = qc_exam!(provider: provider, instrument: instrument)
    creat = qc_exam!(provider: provider, instrument: instrument, sigtap_code: "0202010317", name: "Creatinina", instrument_test_code: "CRE",
                     analytes: [ LabHelpers::GLUCOSE.first.merge("key" => "creatinina", "name" => "Creatinina", "decimals" => 2, "entry_min" => nil,
                                                                "entry_max" => nil, "critical_low" => nil, "critical_high" => nil) ])
    lot = qc_lot!(qc_material!(provider, exams: [ glucose, creat ]), lot_number: plan::LOT, barcodes: plan::BARCODES)
    plan::TARGETS.each do |level, by_code|
      by_code.each do |code, (mean, sd, _decimals)|
        qc_target!(lot, level: level, analyte_key: plan::ANALYTES.fetch(code).first, instrument: instrument, mean: mean, sd: sd)
      end
    end
    @token = middleware_token!(provider, simulated: true)
  end

  let(:log_io) { StringIO.new }
  let(:logger) { Logger.new(log_io) }
  let(:client) do
    session = ActionDispatch::Integration::Session.new(Rails.application)
    session.host! test_city_host
    Class.new do
      define_method(:initialize) { |s, t| @s = s; @t = t }
      attr_reader :last_status

      define_method(:post) do |body|
        @s.post "/hl7/v2", params: body, headers: { "CONTENT_TYPE" => "application/hl7-v2", "Authorization" => "Bearer #{@t}" }
        @last_status = @s.response.status
        [ @last_status, @s.response.body ]
      end
    end.new(session, @token)
  end

  it "corrida aprovada: AA, quatro valores, corrida aprovada" do
    expect(FakeMiddleware::Runner.qc(client: client, logger: logger, scenario: "approved", on: Date.new(2026, 10, 18))).to eq("AA")
    expect(LabQcValue.pluck(:outcome)).to eq(%w[ok ok ok ok])
    expect(LabQcRun.sole.status).to eq("approved")
  end

  it "corrida reprovada por 2-2s: AA, bloqueio da glicose; creatinina aceita" do
    expect(FakeMiddleware::Runner.qc(client: client, logger: logger, scenario: "reject_2_2s", on: Date.new(2026, 10, 18))).to eq("AA")
    expect(LabQcValue.find_by!(level: "Nível 2", analyte_key: "glicose").rules_fired).to eq(%w[1_2s 2_2s])
    expect(LabQcValue.where(analyte_key: "creatinina").pluck(:outcome)).to eq(%w[ok ok])
    expect(LabQcBlock.active.pluck(:analyte_key)).to eq([ "glicose" ])
  end

  it "loga só cenário, MSH-10 e MSA; cenário desconhecido é recusado" do
    FakeMiddleware::Runner.qc(client: client, logger: logger, scenario: "approved", on: Date.new(2026, 10, 18))
    text = log_io.string.lines.map { |line| line.split(" -- : ", 2).last }.join.gsub(/MSH-10 M[0-9a-f]+/, "MSH-10 M")
    expect(text).to include("controle approved MSH-10 M MSA AA")
    [ *plan::BARCODES.values, "88.2", "278.1", @token ].each { |secret| expect(text).not_to include(secret) }
    expect { FakeMiddleware::Runner.qc(client: client, logger: logger, scenario: "x") }.to raise_error(ArgumentError)
  end
end
