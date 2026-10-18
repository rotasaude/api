require "rails_helper"

# Spec §5.8–§5.9 (F-21.26, F-21.30): com 20 corridas aceitas no lote (por
# nível, analito e aparelho) depois da referência vigente, o sistema sugere
# média e dp; o RT aceita e vira nova versão `laboratory`. Levey-Jennings
# com a versão de cada ponto (Review Focus 1: referência trocada no meio da
# corrida não recalcula o que já entrou).
RSpec.describe "CIQ — referência do laboratório e Levey-Jennings", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  before do
    travel_to(Time.zone.now.change(hour: 12))
    qc_city!
  end

  after { travel_back }

  let(:s) { qc_scenario! } # bula aceita há 30 dias
  let(:lead) { lab_releaser!(s.provider, lead: true) }
  let(:staff) { lab_staff! }
  # z alternando de lado: nenhuma regra dispara na história.
  let(:offsets) { [ 0.3, -0.5, 0.8, -0.2, 0.6, -0.9, 0.4, -0.3, 1.1, -0.6, 0.2, -0.4, 0.7, -0.8, 0.5, -0.1, 0.9, -0.7, 0.3, -0.2 ] }

  # Uma corrida por dia (dias diferentes = corridas diferentes), os dois níveis.
  def run_on!(day, offset)
    qc_value!(s, "Nível 1", offset, by: staff, now: day)
    qc_value!(s, "Nível 2", -offset, by: staff, now: day + 1)
  end

  def expected(level, offsets)
    values = offsets.map { |o| qc_glucose(level, o) }
    mean = values.sum / values.size
    sd = (values.sum { |v| (v - mean)**2 } / (values.size - 1)).sqrt(20)
    [ Lab::Qc::Decimal.out(mean.round(4)), Lab::Qc::Decimal.out(sd.round(4)) ]
  end

  it "19 corridas: nada; 20: sugestão por nível; o RT aceita; a sugestão aceita some" do
    offsets.first(19).each_with_index { |o, i| run_on!(Time.current - (20 - i).days, o) }
    stepped_up!(lead)
    get "/lab/qc/targets/suggestions", params: { provider_id: s.provider.id }
    expect(json_body["suggestions"]).to eq([])
    run_on!(Time.current - 1.hour, offsets.last)
    get "/lab/qc/targets/suggestions", params: { provider_id: s.provider.id }
    level1 = json_body["suggestions"].find { |x| x["level"] == "Nível 1" }
    mean, sd = expected("Nível 1", offsets)
    expect(level1).to include("lot_id" => s.lot.id, "analyte_key" => "glicose", "instrument_id" => s.instrument.id, "runs" => 20,
                              "mean" => mean, "sd" => sd, "current_version" => 1, "current_source" => "package_insert")
    expect(json_body["suggestions"].size).to eq(2)

    body = { lot_id: s.lot.id, level: "Nível 1", analyte_key: "glicose", instrument_id: s.instrument.id }
    json_post "/lab/qc/targets/suggestions/accept", body
    expect(json_body["error"]).to eq("reason_required") # C6
    json_post "/lab/qc/targets/suggestions/accept", body.merge(reason: "x" * 1001)
    expect(json_body["error"]).to eq("invalid_reason") # C-E11
    body[:reason] = "20 corridas do lote; faixa da bula larga demais"
    json_post "/lab/qc/targets/suggestions/accept", body
    expect(response).to have_http_status(:created)
    expect(json_body).to include("version" => 2, "source" => "laboratory", "based_on_runs" => 20, "mean" => mean, "sd" => sd,
                                 "reason" => "20 corridas do lote; faixa da bula larga demais")
    json_post "/lab/qc/targets/suggestions/accept", body
    expect(response).to have_http_status(:not_found) # nenhuma corrida depois da nova referência
    get "/lab/qc/targets/suggestions", params: { provider_id: s.provider.id }
    expect(json_body["suggestions"].map { |x| x["level"] }).to eq([ "Nível 2" ])
    expect(DomainEvent.where(name: "lab_qc_target.accepted").map(&:payload).last).to include("source" => "laboratory")
    stepped_up!(staff)
    json_post "/lab/qc/targets/suggestions/accept", body.merge(level: "Nível 2")
    expect(response).to have_http_status(:forbidden)
    get "/lab/qc/targets/suggestions", params: { provider_id: s.provider.id }
    expect(response).to have_http_status(:forbidden)
  end

  it "corrida reprovada não conta para a sugestão" do
    offsets.first(19).each_with_index { |o, i| run_on!(Time.current - (20 - i).days, o) }
    qc_value!(s, "Nível 1", 3.5, by: staff, now: Time.current - 2.hours)
    expect(Lab::Qc::Suggestions.find(lot_id: s.lot.id, level: "Nível 1", analyte_key: "glicose", instrument_id: s.instrument.id)).to be_nil
  end

  it "referência trocada no meio da corrida: o valor antigo fica com a versão dele; o gráfico mostra as duas" do
    qc_value!(s, "Nível 1", 0.4, by: staff)
    travel 1.second
    qc_target!(s.lot, level: "Nível 1", analyte_key: "glicose", instrument: s.instrument, mean: 101, sd: 2, source: "laboratory", runs: 20, at: Time.current)
    travel 1.second
    second = qc_value!(s, "Nível 1", value: BigDecimal("105"), by: staff)
    expect(second[:value]).to have_attributes(z_score: BigDecimal("2"), outcome: "ok")
    expect(LabQcValue.order(:entered_at).map { |v| [ v.z_score, v.lab_qc_target.version ] }).to eq([ [ BigDecimal("0.4"), 1 ], [ BigDecimal("2"), 2 ] ])
    stepped_up!(lead)
    period = { from: (Time.zone.today - 31).iso8601, to: Time.zone.today.iso8601 }
    get "/lab/qc/chart", params: { lot_id: s.lot.id, level: "Nível 1", analyte_key: "glicose", instrument_id: s.instrument.id, **period }
    expect(json_body["target"]).to eq("mean" => "101", "sd" => "2", "version" => 2, "source" => "laboratory")
    expect(json_body["points"].first.keys.sort).to eq(%w[at outcome rules_fired target_version value z_score]) # D4: pontos já criados
    expect(json_body["points"].map { |p| p.values_at("value", "z_score", "outcome", "target_version") })
      .to eq([ [ "102", 0.4, "ok", 1 ], [ "105", 2.0, "ok", 2 ] ])
    get "/lab/qc/chart", params: { lot_id: s.lot.id, level: "Nível 1", analyte_key: "glicose", instrument_id: s.instrument.id }
    expect(json_body["points"].size).to eq(2) # C-E5: sem período, últimos 31 dias
    get "/lab/qc/chart", params: { lot_id: s.lot.id, level: "Nível 2", analyte_key: "glicose",
                                   instrument_id: qc_instrument!(s.provider, name: "Outro", hl7_equipment_id: "BIO-03").id, **period }
    expect(json_body).to eq("target" => nil, "points" => [])
    get "/lab/qc/chart", params: { lot_id: s.lot.id, level: "Nível 1", analyte_key: "glicose", instrument_id: s.instrument.id,
                                   from: (Time.zone.today - 60).iso8601, to: (Time.zone.today - 40).iso8601 }
    expect(json_body["points"]).to eq([])
    get "/lab/qc/chart", params: { lot_id: s.lot.id, level: "Nível 1" }
    expect(json_body["error"]).to eq("filter_required")
    chart = { lot_id: s.lot.id, level: "Nível 1", analyte_key: "glicose", instrument_id: s.instrument.id }
    get "/lab/qc/chart", params: chart.merge(from: (Time.zone.today - 367).iso8601, to: Time.zone.today.iso8601)
    expect(response).to have_http_status(:unprocessable_content)
    expect(json_body["error"]).to eq("invalid_period")
    get "/lab/qc/chart", params: chart.merge(from: (Time.zone.today - 366).iso8601, to: Time.zone.today.iso8601)
    expect(response).to have_http_status(:ok)
    get "/lab/qc/chart", params: chart.merge(from: "2026-02-30")
    expect(json_body["error"]).to eq("invalid_date")
    get "/lab/qc/chart", params: chart.merge(from: Time.zone.tomorrow.iso8601, to: Time.zone.today.iso8601)
    expect(json_body["error"]).to eq("invalid_period")
    stepped_up!(staff)
    get "/lab/qc/chart", params: { lot_id: s.lot.id, level: "Nível 1", analyte_key: "glicose", instrument_id: s.instrument.id, **period }
    expect(response).to have_http_status(:forbidden)
  end
end

# Rodada de correção 1: contagem de corridas, limites do gráfico e recusas.
RSpec.describe "CIQ — sugestão e gráfico: bordas e recusas", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  before do
    travel_to(Time.zone.now.change(hour: 12))
    qc_city!
  end

  after { travel_back }

  let(:s) { qc_scenario! }
  let(:lead) { lab_releaser!(s.provider, lead: true) }
  let(:staff) { lab_staff! }
  let(:offsets) { [ 0.3, -0.5, 0.8, -0.2, 0.6, -0.9, 0.4, -0.3, 1.1, -0.6, 0.2, -0.4, 0.7, -0.8, 0.5, -0.1, 0.9, -0.7, 0.3, -0.2 ] }
  let(:chart) { { lot_id: s.lot.id, level: "Nível 1", analyte_key: "glicose", instrument_id: s.instrument.id } }
  let(:key) { { lot_id: s.lot.id, level: "Nível 1", analyte_key: "glicose", instrument_id: s.instrument.id } }

  # Uma corrida por dia, só no Nível 1, terminando ontem.
  def runs!(scenario, count, from: 0)
    count.times.map do |i|
      qc_value!(scenario, "Nível 1", offsets[(from + i) % offsets.size], by: staff, now: Time.current - (count + 1 - i).days)
    end
  end

  def suggestion(scenario = s) = Lab::Qc::Suggestions.find(lot_id: scenario.lot.id, level: "Nível 1", analyte_key: "glicose", instrument_id: scenario.instrument.id)

  def other_instrument_scenario
    instrument = qc_instrument!(s.provider, name: "Outro", hl7_equipment_id: "BIO-09")
    qc_target!(s.lot, level: "Nível 1", analyte_key: "glicose", instrument: instrument, mean: 100, sd: 5)
    qc_target!(s.lot, level: "Nível 2", analyte_key: "glicose", instrument: instrument, mean: 250, sd: 10)
    QcScenarioProxy.new(s, instrument: instrument)
  end

  QcScenarioProxy = Struct.new(:base, :overrides) do
    def initialize(base, overrides) = super(base, overrides)
    def provider = base.provider
    def instrument = overrides[:instrument] || base.instrument
    def lot = overrides[:lot] || base.lot
    def exam = base.exam
    def material = base.material
  end

  describe "gráfico" do
    it "limita a 200 pontos: os mais recentes, em ordem cronológica" do
      201.times { |i| qc_value!(s, "Nível 1", i.even? ? 0.3 : -0.3, by: staff, now: Time.current - (201 - i).minutes) }
      stepped_up!(lead)
      get "/lab/qc/chart", params: chart
      expect(response).to have_http_status(:ok)
      ats = json_body["points"].map { |p| Time.zone.parse(p["at"]) }
      expect(ats.size).to eq(200)
      expect(ats).to eq(ats.sort)
      newest = LabQcValue.order(:entered_at).pluck(:entered_at).last(200)
      expect(ats).to eq(newest.map { |t| Time.zone.parse(t.iso8601) })
    end

    it "aparelho de outro laboratório: 404; quem não é do laboratório: 403 (nunca 404)" do
      foreign = qc_instrument!(lab_provider!, name: "Alheio", hl7_equipment_id: "BIO-77")
      stepped_up!(lead)
      get "/lab/qc/chart", params: chart.merge(instrument_id: foreign.id)
      expect(response).to have_http_status(:not_found)
      expect(json_body["error"]).to eq("not_found")
      third = lab_releaser!(lab_provider!, lead: true)
      stepped_up!(third)
      get "/lab/qc/chart", params: chart.merge(instrument_id: foreign.id)
      expect(response).to have_http_status(:forbidden)
      get "/lab/qc/chart", params: chart
      expect(response).to have_http_status(:forbidden)
    end

    it "data que não é data (from ou to): 422 invalid_date" do
      stepped_up!(lead)
      [ { from: "abc" }, { to: "abc" }, { to: "2026-13-01" }, { from: "2026-1-1" } ].each do |period|
        get "/lab/qc/chart", params: chart.merge(period)
        expect(response).to have_http_status(:unprocessable_content)
        expect(json_body["error"]).to eq("invalid_date")
      end
    end

    it "pontos sem referência vigente: target null e os pontos continuam listados" do
      qc_value!(s, "Nível 1", 0.4, by: staff)
      stepped_up!(lead)
      # Sem referência vigente (a chave de busca não acha nada): os pontos já gravados seguem com a versão deles.
      allow(LabQcTarget).to receive(:current).and_return(nil)
      get "/lab/qc/chart", params: chart
      expect(response).to have_http_status(:ok)
      expect(json_body["target"]).to be_nil
      expect(json_body["points"].map { |p| p["target_version"] }).to eq([ 1 ])
    end
  end

  describe "contagem de corridas da sugestão" do
    it "corrida em alerta (warning) conta; só o último valor de cada corrida entra" do
      runs!(s, 19)
      # a 20ª corrida: primeiro valor perto da média, o último em alerta (z 2,3)
      qc_value!(s, "Nível 1", 0.1, by: staff, now: Time.current - 1.hour)
      last = qc_value!(s, "Nível 1", 2.3, by: staff, now: Time.current - 30.minutes)
      expect(last[:value].outcome).to eq("warning")
      expect(last[:run].status).to eq("warning")
      found = suggestion
      expect(found.runs).to eq(20)
      values = LabQcValue.joins(:lab_qc_run).order(:entered_at).group_by(&:lab_qc_run_id).values.map { |rows| rows.last.value }
      mean = values.sum / 20
      expect(found.mean).to eq(mean.round(4))
    end

    it "valores de outro aparelho ou de outro lote não entram" do
      runs!(s, 19)
      other = other_instrument_scenario
      runs!(other, 5)
      expect(suggestion).to be_nil
      lot2 = qc_lot!(s.material)
      qc_target!(lot2, level: "Nível 1", analyte_key: "glicose", instrument: s.instrument, mean: 100, sd: 5)
      qc_target!(lot2, level: "Nível 2", analyte_key: "glicose", instrument: s.instrument, mean: 250, sd: 10)
      runs!(QcScenarioProxy.new(s, lot: lot2), 5)
      expect(suggestion).to be_nil
      expect(suggestion(other)).to be_nil
    end

    it "valor sem variação (dp 0): nenhuma sugestão" do
      20.times { |i| qc_value!(s, "Nível 1", 0, by: staff, now: Time.current - (21 - i).days) }
      expect(LabQcRun.where(status: LabQcRun::ACCEPTED).count).to eq(20)
      expect(suggestion).to be_nil
    end

    it "lote encerrado some da lista; aceitar nele: 422 lot_closed e nada gravado" do
      runs!(s, 20)
      stepped_up!(lead)
      get "/lab/qc/targets/suggestions", params: { provider_id: s.provider.id }
      expect(json_body["suggestions"].size).to eq(1)
      s.lot.update_columns(status: "closed", closed_on: Time.zone.today)
      get "/lab/qc/targets/suggestions", params: { provider_id: s.provider.id }
      expect(json_body["suggestions"]).to eq([])
      targets = LabQcTarget.count
      json_post "/lab/qc/targets/suggestions/accept", key.merge(reason: "motivo")
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body["error"]).to eq("lot_closed")
      expect(LabQcTarget.count).to eq(targets)
    end
  end

  describe "recusas" do
    before { runs!(s, 20) }

    def refused_without_writing(status, error)
      targets = LabQcTarget.count
      events = DomainEvent.where(name: "lab_qc_target.accepted").count
      yield
      expect(response).to have_http_status(status)
      expect(json_body["error"]).to eq(error)
      expect(LabQcTarget.count).to eq(targets)
      expect(DomainEvent.where(name: "lab_qc_target.accepted").count).to eq(events)
    end

    it "RT sem step-up: 401 mfa_required" do
      sign_in_as(lead)
      refused_without_writing(:unauthorized, "mfa_required") { json_post "/lab/qc/targets/suggestions/accept", key.merge(reason: "motivo") }
    end

    it "liberador que não é RT nem substituto: 403 missing_role" do
      plain = lab_releaser!(s.provider)
      stepped_up!(plain)
      refused_without_writing(:forbidden, "missing_role") { json_post "/lab/qc/targets/suggestions/accept", key.merge(reason: "motivo") }
    end

    it "motivo só com espaços: 422 reason_required" do
      stepped_up!(lead)
      refused_without_writing(:unprocessable_content, "reason_required") { json_post "/lab/qc/targets/suggestions/accept", key.merge(reason: "   ") }
    end

    it "lista de outro laboratório: 403; provider_id ausente ou inválido: 404" do
      stepped_up!(lead)
      get "/lab/qc/targets/suggestions", params: { provider_id: lab_provider!.id }
      expect(response).to have_http_status(:forbidden)
      get "/lab/qc/targets/suggestions"
      expect(response).to have_http_status(:not_found)
      expect(json_body["error"]).to eq("not_found")
      get "/lab/qc/targets/suggestions", params: { provider_id: "abc" }
      expect(response).to have_http_status(:not_found)
    end
  end
end
