require "rails_helper"
require "csv"

# Spec §7 (relatórios) com dashboard D13: produção por unidade de origem,
# exame, setor e liberador com valor SIGTAP; rejeições por motivo e unidade;
# prazo cumprido × atrasado × pendente. Tela e CSV. Sem dado de paciente.
# Tempo congelado ao meio-dia: nada de flake de mês/data perto da meia-noite.
RSpec.describe "Laboratório — relatórios", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  before do
    travel_to(Time.zone.local(Time.zone.today.year, Time.zone.today.month, 10, 12, 0, 1)) # dia 10: longe das bordas do mês
    sigtap_with_amount!(amount) # antes de lab_city!: o helper do 21a só cria a competência se ela não existe
    lab_city!
  end

  after { travel_back }

  let(:amount) { 185 }
  let(:provider) { lab_provider! }
  let(:lead) { lab_releaser!(provider, lead: true) }
  let(:glucose) { lab_exam!(provider: provider, delivery_days: 1) }
  let(:month) { Time.zone.today.strftime("%Y-%m") }

  # A competência ativa é imutável: a tabela já nasce com o valor (VL_SA) ou sem ele.
  def sigtap_with_amount!(cents)
    release = TerminologyRelease.create!(kind: "sigtap", version: Time.zone.today.strftime("%Y%m"), source_sha256: "e" * 64,
                                         imported_by: "rspec", imported_at: Time.current, status: "importing")
    ClinicalRecordHelpers::SIGTAP.each { |code, name| SigtapProcedure.create!(release: release, code: code, name: name, amount_sa_cents: cents) }
    release.update!(status: "active", activated_at: Time.current)
  end

  # Libera em um instante exato (fuso da cidade), com o TOTP daquele instante.
  def release_at!(req, releaser, time)
    item = type!(req.items.first, { glicose: "98" })
    travel_to(time) { Lab::Release.call(requisition: req, item_ids: [ item.id ], signature: "advanced", totp: totp_for(releaser), by: releaser) }
  end

  def received_for(unit)
    received_requisition!(provider: provider, exams: [ glucose ], unit: unit)
  end

  def release_one!(prov, exam, releaser, unit, offset: 0)
    req = received_requisition!(provider: prov, exams: [ exam ], unit: unit)
    item = type!(req.items.first, { glicose: "98" })
    travel(offset.seconds) { Lab::Release.call(requisition: req, item_ids: [ item.id ], signature: "advanced", totp: totp_for(releaser), by: releaser) }
    req
  end

  it "produção, rejeições e prazo, com CSV" do
    unit = create_unit("UBS Produção").tap { |u| u.update!(collects_samples: true) }
    2.times { |i| release_one!(provider, glucose, lead, unit, offset: i * 31) }
    rejected = open_requisition!(provider: provider, exams: [ glucose ], unit: unit)
    staff = lab_staff!
    Lab::CollectSample.call(sample: rejected.samples.first, by: staff)
    reason = LabRejectionReason.create!(exam_provider: provider, name: "Amostra hemolisada")
    Lab::ReceiveSample.call(barcode: rejected.samples.first.barcode, decision: "reject", reason_id: reason.id, by: staff)

    sign_in_as(lead)
    get "/lab/reports/production", params: { provider_id: provider.id, month: month }
    expect(json_body["rows"].sole).to include("origin_unit" => { "id" => unit.id, "name" => "UBS Produção" }, "sigtap_code" => "0202010473",
                                              "exam_name" => "Glicose", "sector" => "biochemistry", "quantity" => 2, "sigtap_value_cents" => 370)
    expect(json_body["rows"].sole["releaser"]).to include("id" => lead.id)
    expect(json_body).to include("total_quantity" => 2, "total_value_cents" => 370)
    get "/lab/reports/rejections", params: { month: month }
    expect(json_body["rows"].sole).to include("reason" => { "id" => reason.id, "name" => "Amostra hemolisada" }, "count" => 1)
    get "/lab/reports/turnaround", params: { month: month }
    expect(json_body["rows"].sole).to include("sigtap_code" => "0202010473", "on_time" => 2, "late" => 0, "pending" => 1)
    get "/lab/reports/production.csv", params: { month: month }
    csv = CSV.parse(response.body, headers: true)
    expect(csv.headers).to eq(%w[origin_unit sigtap_code exam_name sector releaser quantity sigtap_value_cents])
    expect(csv.first["quantity"]).to eq("2")
    expect(response.headers["Content-Disposition"]).to include("laboratorio-production-#{month}.csv")
    get "/lab/reports/rejections.csv", params: { month: month }
    expect(response.media_type).to eq("text/csv")
    rej = CSV.parse(response.body, headers: true)
    expect(rej.headers).to eq(%w[reason origin_unit count])
    expect(rej.first.to_h).to eq("reason" => "Amostra hemolisada", "origin_unit" => "UBS Produção", "count" => "1")
    get "/lab/reports/turnaround.csv", params: { month: month }
    tat = CSV.parse(response.body, headers: true)
    expect(tat.headers).to eq(%w[sigtap_code exam_name on_time late pending])
    expect(tat.first.to_h).to eq("sigtap_code" => "0202010473", "exam_name" => "Glicose", "on_time" => "2", "late" => "0", "pending" => "1")
    get "/lab/reports/turnaround", params: { month: "2026-13" }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_body["error"]).to eq("invalid_month")
    sign_in_as(lab_staff!)
    get "/lab/reports/production", params: { month: month }
    expect(response).to have_http_status(:forbidden)
  end

  it "o liberador do laboratório A, com 'todos', nunca vê os números do B" do
    other = lab_provider!(name: "Laboratório B #{SecureRandom.hex(2)}")
    other_glucose = lab_exam!(provider: other, delivery_days: 1)
    other_lead = lab_releaser!(other, lead: true)
    unit_a = create_unit("UBS A").tap { |u| u.update!(collects_samples: true) }
    unit_b = create_unit("UBS B").tap { |u| u.update!(collects_samples: true) }
    release_one!(provider, glucose, lead, unit_a)
    2.times { |i| release_one!(other, other_glucose, other_lead, unit_b, offset: i * 31) }

    sign_in_as(lead)
    get "/lab/reports/production", params: { month: month }
    expect(response).to have_http_status(:ok)
    expect(json_body["rows"].sole).to include("quantity" => 1)
    expect(json_body).to include("total_quantity" => 1, "total_value_cents" => 185)
    expect(response.body).not_to include("UBS B")
    get "/lab/reports/turnaround", params: { month: month }
    expect(json_body["rows"].sole).to include("on_time" => 1)
    get "/lab/reports/production.csv", params: { month: month }
    expect(response.body).not_to include("UBS B")

    get "/lab/reports/production", params: { month: month, provider_id: other.id }
    expect(response).to have_http_status(:forbidden)

    sign_in_as(lab_admin!)
    get "/lab/reports/production", params: { month: month }
    expect(json_body).to include("total_quantity" => 3, "total_value_cents" => 555)
    get "/lab/reports/production", params: { month: month, provider_id: other.id }
    expect(json_body).to include("total_quantity" => 2)
  end

  context "sem valor SIGTAP na tabela" do
    let(:amount) { nil }

    it "o valor é 0, em inteiros; CSV sem fórmula e sem dado de paciente" do
      unit = create_unit("=HYPERLINK(\"x\")").tap { |u| u.update!(collects_samples: true) }
      req = release_one!(provider, glucose, lead, unit)
      sign_in_as(lead)
      get "/lab/reports/production", params: { month: month }
      expect(json_body["rows"].sole["sigtap_value_cents"]).to eq(0)
      expect(json_body["total_value_cents"]).to eq(0)
      get "/lab/reports/production.csv", params: { month: month }
      expect(CSV.parse(response.body, headers: true).first["origin_unit"]).to start_with("'")
      patient = req.patient
      forbidden = [ patient.full_name, patient.cpf, patient.mother_name, "Joana da Silva", req.samples.first.barcode ]
      expect(forbidden).to all(be_present)
      texts = []
      %w[production production.csv rejections rejections.csv turnaround turnaround.csv].each do |path|
        get "/lab/reports/#{path}", params: { month: month }
        texts += [ response.body, response.headers["Content-Disposition"].to_s ]
      end
      forbidden.each { |value| texts.each { |text| expect(text).not_to include(value) } }
    end
  end

  it "mês fora do período não traz o que foi liberado agora" do
    unit = create_unit("UBS Mês").tap { |u| u.update!(collects_samples: true) }
    release_one!(provider, glucose, lead, unit)
    sign_in_as(lead)
    get "/lab/reports/production", params: { month: (Time.zone.today << 1).strftime("%Y-%m") }
    expect(json_body).to include("rows" => [], "total_quantity" => 0, "total_value_cents" => 0)
  end

  it "prazo: liberar no dia previsto é no prazo; um dia depois é atrasado" do
    unit = create_unit("UBS Prazo").tap { |u| u.update!(collects_samples: true) }
    on_due = received_for(unit)   # aberta no dia 10, prevista para o dia 11
    after_due = received_for(unit)
    release_at!(on_due, lead, Time.zone.local(Time.zone.today.year, Time.zone.today.month, 11, 23, 59, 0))
    release_at!(after_due, lead, Time.zone.local(Time.zone.today.year, Time.zone.today.month, 12, 0, 0, 30))
    expect(on_due.reload.expected_delivery_on).to eq(Date.new(Time.zone.today.year, Time.zone.today.month, 11))

    sign_in_as(lead)
    get "/lab/reports/turnaround", params: { month: month }
    expect(json_body["rows"].sole).to include("on_time" => 1, "late" => 1, "pending" => 0)
  end

  it "fronteira do mês no fuso da cidade: 23:59 do último dia é do mês, 00:00 do seguinte não" do
    unit = create_unit("UBS Fronteira").tap { |u| u.update!(collects_samples: true) }
    last = received_for(unit)
    first_of_next = received_for(unit)
    year = Time.zone.today.year
    mon = Time.zone.today.month
    end_of_month = Time.zone.local(year, mon, 1).end_of_month
    release_at!(last, lead, end_of_month.change(hour: 23, min: 59, sec: 30))
    release_at!(first_of_next, lead, (end_of_month + 1.day).beginning_of_day + 10.seconds)
    next_month = (Time.zone.local(year, mon, 1) + 1.month).strftime("%Y-%m")

    sign_in_as(lead)
    get "/lab/reports/production", params: { month: month }
    expect(json_body).to include("total_quantity" => 1)
    get "/lab/reports/production", params: { month: next_month }
    expect(json_body).to include("total_quantity" => 1)
  end
end
