require "rails_helper"

# Módulo 25, Task 14 (contrato §15 K7): a negativa semanal por unidade
# notificadora. A semana é a da SUSPEITA; a corrente conta como futura; o GET
# sem semana usa a anterior. "Hoje" é a segunda-feira 2026-01-05 (SE 01/2026,
# de 04 a 10/01; a SE 53/2025 foi de 28/12 a 03/01).
RSpec.describe "Vigilância — negativa semanal", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let!(:city) { surveillance_city! }
  let(:officer) { surveillance_officer! }
  let(:json_headers) { { "Content-Type" => "application/json" } }

  before { sign_in_as(officer) }

  # A lista nacional de doenças entra em vigor depois de janeiro: as
  # notificações nascem no relógio real (com suspected_at explícito) e só então
  # o tempo viaja. Todo exemplo chama monday! antes de usar a API.
  def monday! = travel_to(Time.zone.local(2026, 1, 5, 10))
  def case_at(unit, day, n:, **over) = notification!(patient: surveillance_patient!(n), unit: unit, suspected_at: day.in_time_zone.change(hour: 12), **over)

  def notifying_unit(name, **attrs)
    create_unit(name).tap { |unit| unit.update!(notifying: true, **attrs) }
  end

  let!(:ubs_a) { notifying_unit("UBS Alfa") }
  let!(:ubs_b) { notifying_unit("UBS Beta") }
  let!(:ubs_c) { notifying_unit("UBS Gama") }

  def record(unit_id, week)
    post "/surveillance/weekly_negatives", params: { unit_id: unit_id, week: week }.to_json, headers: json_headers
  end

  def statuses = json_body["units"].to_h { |row| [ row["unit"]["name"], row["status"] ] }

  it "registra a negativa de 2025-53, devolve 201 com a unidade e publica o evento só com ids" do
    monday!
    record(ubs_a.id, "2025-53")

    expect(response).to have_http_status(:created)
    expect(json_body).to eq("week" => "2025-53", "unit" => { "id" => ubs_a.id, "cnes" => ubs_a.cnes, "name" => "UBS Alfa" },
                            "status" => "negative")
    report = WeeklyNegativeReport.find_by!(health_unit: ubs_a, week: "2025-53")
    expect(report.recorded_by_user_id).to eq(officer.id)
    event = DomainEvent.where(name: "weekly_negative.recorded").order(:occurred_at).last
    expect(event.payload).to eq("weekly_negative_report_id" => report.id, "user_id" => officer.id)
  end

  it "a segunda vez é 409 already_recorded, sem segunda linha nem segundo evento" do
    monday!
    record(ubs_a.id, "2025-53")
    expect { record(ubs_a.id, "2025-53") }.not_to change { DomainEvent.where(name: "weekly_negative.recorded").count }

    expect(response).to have_http_status(:conflict)
    expect(json_body).to eq("error" => "already_recorded")
    expect(WeeklyNegativeReport.where(health_unit: ubs_a).count).to eq(1)
  end

  it "uma corrida que escapa à conferência cai no índice único: 409, nunca 500 nem mensagem do Postgres" do
    monday!
    allow(WeeklyNegativeReport).to receive(:exists?).and_return(false)
    WeeklyNegativeReport.create!(health_unit: ubs_a, week: "2025-53", recorded_by_user: officer)

    record(ubs_a.id, "2025-53")

    expect(response).to have_http_status(:conflict)
    expect(response.body).to eq({ error: "already_recorded" }.to_json)
    expect(WeeklyNegativeReport.where(health_unit: ubs_a).count).to eq(1)
  end

  it "a semana corrente é 422 future_week; uma posterior também" do
    monday!
    record(ubs_a.id, "2026-01")
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_body).to eq("error" => "future_week")

    record(ubs_a.id, "2026-10")
    expect(json_body).to eq("error" => "future_week")
    expect(WeeklyNegativeReport.count).to eq(0)
  end

  it "a corrente é futura em todos os dias dela, inclusive o sábado; só a partir do domingo deixa de ser" do
    travel_to Time.zone.local(2026, 1, 9, 23, 30)
    record(ubs_a.id, "2026-01")
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_body).to eq("error" => "future_week")

    travel_to Time.zone.local(2026, 1, 10, 0, 30)
    record(ubs_a.id, "2026-01")
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_body).to eq("error" => "future_week")

    travel_to Time.zone.local(2026, 1, 11, 0, 30)
    record(ubs_a.id, "2026-01")
    expect(response).to have_http_status(:created)
  end

  it "semana que não existe, malformada ou que não é texto é 422 invalid_week" do
    monday!
    [ "2026-53", "2026-00", "26-01", "2026-1", "", nil, 202601, [ "2025-53" ] ].each do |week|
      record(ubs_a.id, week)
      expect(response).to have_http_status(:unprocessable_entity), "week=#{week.inspect}"
      expect(json_body).to eq("error" => "invalid_week")
    end
  end

  it "unidade com notificação suspeita em 2026-01-02 (fora de possible/dismissed) é 409 unit_has_notifications" do
    case_at(ubs_a, Date.new(2026, 1, 2), n: 1)
    monday!

    record(ubs_a.id, "2025-53")

    expect(response).to have_http_status(:conflict)
    expect(json_body).to eq("error" => "unit_has_notifications")
    expect(WeeklyNegativeReport.count).to eq(0)
  end

  it "notificação possible ou descartada não tira a negativa" do
    case_at(ubs_a, Date.new(2026, 1, 2), n: 1, status: "possible")
    case_at(ubs_a, Date.new(2026, 1, 2), n: 2).update_columns(status: "dismissed")
    monday!

    record(ubs_a.id, "2025-53")

    expect(response).to have_http_status(:created)
  end

  it "unidade inexistente, fora do formato, inativa ou não notificadora é 422 invalid_unit" do
    inactive = notifying_unit("UBS Inativa", active: false)
    plain = create_unit("UBS Comum").tap { |unit| unit.update!(notifying: false) }
    monday!

    [ SecureRandom.uuid, "não-é-uuid", nil, 7, inactive.id, plain.id ].each do |unit_id|
      record(unit_id, "2025-53")
      expect(response).to have_http_status(:unprocessable_entity), "unit_id=#{unit_id.inspect} #{response.body}"
      expect(json_body).to eq("error" => "invalid_unit")
    end
    expect(WeeklyNegativeReport.count).to eq(0)
  end

  it "unit_id e week só do corpo: na URL valem como ausentes" do
    monday!
    post "/surveillance/weekly_negatives?unit_id=#{ubs_a.id}&week=2025-53", params: {}.to_json, headers: json_headers

    expect(response).to have_http_status(:unprocessable_entity)
    expect(WeeklyNegativeReport.count).to eq(0)
  end

  describe "GET" do
    before { case_at(ubs_b, Date.new(2026, 1, 2), n: 1) }

    def negative_for_a! = WeeklyNegativeReport.create!(health_unit: ubs_a, week: "2025-53", recorded_by_user: officer)

    it "2025-53 mostra negative, with_cases e pending nas três unidades, por nome" do
      negative_for_a!
      monday!

      get "/surveillance/weekly_negatives", params: { week: "2025-53" }

      expect(response).to have_http_status(:ok)
      expect(json_body["week"]).to eq("2025-53")
      expect(json_body["units"].map { |row| row["unit"]["name"] }).to eq([ "UBS Alfa", "UBS Beta", "UBS Gama" ])
      expect(json_body["units"].first["unit"]).to eq("id" => ubs_a.id, "cnes" => ubs_a.cnes, "name" => "UBS Alfa")
      expect(statuses).to eq("UBS Alfa" => "negative", "UBS Beta" => "with_cases", "UBS Gama" => "pending")
    end

    it "with_cases vence a negativa gravada antes do caso" do
      negative_for_a!
      case_at(ubs_a, Date.new(2025, 12, 30), n: 2)
      monday!

      get "/surveillance/weekly_negatives", params: { week: "2025-53" }

      expect(statuses["UBS Alfa"]).to eq("with_cases")
    end

    it "sem semana usa a anterior à corrente (2025-53) e lista só unidades ativas notificadoras" do
      negative_for_a!
      notifying_unit("UBS Inativa", active: false)
      create_unit("UBS Comum").update!(notifying: false)
      monday!

      get "/surveillance/weekly_negatives"

      expect(json_body["week"]).to eq("2025-53")
      expect(statuses).to eq("UBS Alfa" => "negative", "UBS Beta" => "with_cases", "UBS Gama" => "pending")
    end

    it "a semana corrente pode ser consultada (tudo pending)" do
      monday!

      get "/surveillance/weekly_negatives", params: { week: "2026-01" }

      expect(json_body["week"]).to eq("2026-01")
      expect(statuses.values.uniq).to eq([ "pending" ])
    end

    it "semana malformada é 422 invalid_week; outra chave na query, 422 invalid_request" do
      monday!

      get "/surveillance/weekly_negatives", params: { week: "2026-53" }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body).to eq("error" => "invalid_week")

      get "/surveillance/weekly_negatives", params: { week: "" }
      expect(json_body).to eq("error" => "invalid_week")

      get "/surveillance/weekly_negatives", params: { week: "2025-53", unit_id: ubs_a.id }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body).to eq("error" => "invalid_request")
    end
  end

  describe "acesso" do
    it "sem o papel surveillance: 403 no GET e no POST, nada gravado" do
      sign_in_as(staff_with("outro@cidade.gov.br", "viewer"))
      monday!

      get "/surveillance/weekly_negatives"
      expect(response).to have_http_status(:forbidden)
      record(ubs_a.id, "2025-53")
      expect(response).to have_http_status(:forbidden)
      expect(WeeklyNegativeReport.count).to eq(0)
    end

    it "com o módulo desligado: 403 feature_disabled" do
      Platform::Features.set!(city: Current.city, key: "surveillance", enabled: false, maintainer: ledi_maintainer!)
      monday!

      record(ubs_a.id, "2025-53")

      expect(response).to have_http_status(:forbidden)
      expect(json_body["error"]).to eq("feature_disabled")
    end

    it "não grava trilha de pessoa" do
      monday!
      expect { get "/surveillance/weekly_negatives" }.not_to change { DomainEvent.where(name: "clinical_record.viewed").count }
    end
  end
end
