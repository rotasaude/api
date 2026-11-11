require "rails_helper"

# Módulo 32a (ADR 0050; contrato §11 e §14 Q15, Q25; plano, Task 15): painel
# do gestor da UPA — só contagens, com "lt5" de 1 a 4 (mediana e p90 com a
# contagem de 1 a 4 também; com 0, nulos). Lêem municipal_admin e analyst; sem
# trilha; nada nominal. O `registered_in_error` fica fora de toda contagem; o
# provisório conta como qualquer visita. Tudo em outubro de 2026 (fuso da
# cidade), lido em 5/11/2026.
RSpec.describe "Urgência — painel do gestor", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let!(:city) { urgency_city! }
  let(:upa) { upa!(name: "UPA 24h Centro") }
  let(:nurse) { upa_nurse!(upa) }
  let(:doctor) { upa_doctor!(upa) }
  let(:base) { Time.zone.local(2026, 10, 5, 8, 0) }
  let(:reader) { staff_with("analista-#{SecureRandom.hex(3)}@cidade.gov.br", "analyst") }

  def dashboard(params = { month: "2026-10" }) = get("/urgency/dashboard", params: params)
  def row(section, color) = json_body[section].find { |item| item["color"] == color }

  # Um encontro que chega em `at`, é classificado `classify_after` minutos
  # depois com `color` e, com `call_after`, chamado pelo médico esses minutos
  # depois da classificação. Volta o relógio para `at`.
  def visit!(at:, color: nil, classify_after: 10, call_after: nil, unit: upa, unidentified: nil)
    travel_to(at)
    encounter = unidentified ? arrived!(unit, unidentified: unidentified) : arrived!(unit)
    return encounter unless color

    travel_to(at + classify_after.minutes)
    classified!(encounter, color: color, by: unit == upa ? nurse : upa_nurse!(unit))
    return encounter unless call_after

    travel_to(at + (classify_after + call_after).minutes)
    called!(encounter, by: unit == upa ? doctor : upa_doctor!(unit))
  end

  def left!(encounter, after: 5, kind: "left_without_care", reason: nil)
    travel_to(Time.current + after.minutes)
    body = { "kind" => kind }
    body["reason"] = reason if reason
    result = Urgency::RecordOutcome.call(encounter: encounter.reload, attrs: body, by: upa_reception!, team: nil)
    raise "left! recusado: #{result.reason} #{result.details}" if result.failure?

    encounter.reload
  end

  def read_dashboard!(params = { month: "2026-10" })
    travel_to(Time.zone.local(2026, 11, 5, 10, 0))
    sign_in_as(reader)
    dashboard(params)
    expect(response).to have_http_status(:ok)
  end

  describe "contagens, tempos e supressão" do
    let!(:greens) do
      # Porta → classificação de 10 a 15 min; cinco chamados 30, 40, 50, 60 e
      # 130 min depois da 1ª classificação (o de 130 estoura os 120 do verde).
      [ 30, 40, 50, 60, 130, nil ].each_with_index.map do |call_after, i|
        visit!(at: base + i.hours, color: "green", classify_after: 10 + i, call_after: call_after)
      end
    end

    before do
      visit!(at: base + 1.day, color: "red", classify_after: 3)
      visit!(at: base + 1.day + 1.hour, color: "red", classify_after: 5, unidentified: "Homem de uns 40 anos, camisa azul")
      # Vigente na chamada: amarelo chamado aos 20 min; reclassificado vermelho
      # DEPOIS da chamada (conta em by_color como vermelho, no tempo até o
      # médico como amarelo).
      reclassified = visit!(at: base + 2.days, color: "yellow", classify_after: 4, call_after: 20)
      travel_to(Time.current + 5.minutes)
      classified!(reclassified, color: "red", by: nurse)
      # Evasões: antes (sem classificação) e depois (amarelo que saiu).
      left!(visit!(at: base + 3.days))
      left!(visit!(at: base + 3.days + 1.hour, color: "yellow", classify_after: 8), after: 30)
      # Registro por engano (Q25): fora de TODA contagem, com e sem classificação.
      left!(visit!(at: base + 4.days), kind: "registered_in_error", reason: "Chegada aberta em duplicidade")
      left!(visit!(at: base + 4.days + 1.hour, color: "green", classify_after: 2),
            kind: "registered_in_error", reason: "Paciente registrado na unidade errada")
      # Fronteira do mês no fuso da cidade: 31/10 23:30 conta; 01/11 00:30 não.
      visit!(at: Time.zone.local(2026, 10, 31, 23, 30), color: "blue", classify_after: 20)
      visit!(at: Time.zone.local(2026, 11, 1, 0, 30), color: "orange", classify_after: 1)
      # Outra UPA: fora do recorte por unidade.
      visit!(at: base + 6.days, color: "green", unit: upa!(name: "UPA Norte"))
    end

    it "porta → classificação pela 1ª cor; tempos em minutos inteiros; 1 a 4 vira lt5; 0 tem tempos nulos" do
      read_dashboard!(month: "2026-10", health_unit_id: upa.id)
      expect(json_body["month"]).to eq("2026-10")
      expect(json_body["units"]).to eq([ { "id" => upa.id, "name" => "UPA 24h Centro" } ])
      expect(row("door_to_classification", "green")).to eq("color" => "green", "count" => 6, "median_minutes" => 13, "p90_minutes" => 15)
      expect(row("door_to_classification", "red")).to eq("color" => "red", "count" => "lt5", "median_minutes" => "lt5", "p90_minutes" => "lt5")
      expect(row("door_to_classification", "orange")).to eq("color" => "orange", "count" => 0, "median_minutes" => nil, "p90_minutes" => nil)
      expect(json_body["door_to_classification"].map { |item| item["color"] }).to eq(Urgency::Catalog::COLORS)
    end

    it "classificação → médico e estouro pela classificação vigente na chamada" do
      read_dashboard!(month: "2026-10", health_unit_id: upa.id)
      expect(row("classification_to_physician", "green")).to eq("color" => "green", "count" => 5, "median_minutes" => 50, "p90_minutes" => 102)
      expect(row("classification_to_physician", "yellow")).to include("count" => "lt5", "median_minutes" => "lt5")
      expect(row("classification_to_physician", "red")).to include("count" => 0, "median_minutes" => nil)
      expect(row("over_max_wait", "green")).to eq("color" => "green", "count" => 5, "over" => "lt5")
      # O amarelo chamado aos 20 min e o amarelo que saiu aos 30 min: ninguém além dos 60.
      expect(row("over_max_wait", "yellow")).to eq("color" => "yellow", "count" => "lt5", "over" => 0)
      expect(row("over_max_wait", "red")).to eq("color" => "red", "count" => 0, "over" => 0)
    end

    it "por cor vigente, por desfecho, evasão e permanência — sem o registro por engano" do
      read_dashboard!(month: "2026-10", health_unit_id: upa.id)
      expect(json_body["by_color"]).to eq("red" => "lt5", "orange" => 0, "yellow" => "lt5", "green" => 6, "blue" => "lt5",
                                          "unclassified" => "lt5")
      expected_outcomes = (Urgency::Catalog::OUTCOMES - Urgency::Catalog::NON_CARE_OUTCOMES).index_with(0).merge("left_without_care" => "lt5")
      expect(json_body["by_outcome"]).to eq(expected_outcomes)
      expect(json_body["evasion"]).to eq("before_classification" => "lt5", "after_classification" => "lt5")
      expect(json_body["stay"]).to eq("count" => "lt5", "median_minutes" => "lt5", "p90_minutes" => "lt5")
    end

    it "sem health_unit_id, todas as UPAs ativas (ordenadas pelo nome); nada nominal e sem trilha" do
      expect { read_dashboard! }.not_to(change { DomainEvent.where(name: "clinical_record.viewed").count })
      expect(json_body["units"].map { |unit| unit["name"] }).to eq([ "UPA 24h Centro", "UPA Norte" ])
      expect(row("door_to_classification", "green")["count"]).to eq(7)
      patients = UrgencyEncounter.includes(attendance: :patient).map { |e| e.attendance.patient }
      patients.each do |patient|
        expect(response.body).not_to include(patient.id)
        expect(response.body).not_to include(patient.full_name) if patient.full_name
      end
      expect(response.body).not_to include("camisa azul")
      UrgencyEncounter.pluck(:id).each { |id| expect(response.body).not_to include(id) }
    end
  end

  # Ruling Q28 item 5: o classificado que saiu sem ser chamado entra no
  # estouro da cor (denominador) e, se esperou além do tempo máximo da
  # classificação vigente desde a 1ª classificação, no numerador.
  it "o classificado que saiu sem ser chamado conta no estouro pela espera até a saída" do
    5.times { |i| left!(visit!(at: base + i.hours, color: "green", classify_after: 5), after: 130) }
    left!(visit!(at: base + 6.hours, color: "green", classify_after: 5), after: 60)
    visit!(at: base + 7.hours, color: "green", classify_after: 5, call_after: 30)
    read_dashboard!
    expect(row("over_max_wait", "green")).to eq("color" => "green", "count" => 7, "over" => 5)
    expect(row("classification_to_physician", "green")["count"]).to eq("lt5")
  end

  # Decisão 11 da spec: evasão é só o `left_without_care` (antes ou depois da
  # classificação); o `left_against_advice` conta só em by_outcome.
  it "a saída contra a orientação médica fica em by_outcome e fora da evasão" do
    # Tabelas publicadas antes da data simulada (a consulta roda em outubro de 2026).
    travel_to(base - 1.day)
    ciap2_release!; cid10_release!; sigtap_release!
    encounter = visit!(at: base, color: "yellow", call_after: 15)
    finalized_urgency!(encounter, doctor: doctor)
    result = Urgency::RecordOutcome.call(encounter: encounter.reload, attrs: { "kind" => "left_against_advice" }, by: doctor, team: nil)
    expect(result).to be_ok
    read_dashboard!
    expect(json_body.dig("by_outcome", "left_against_advice")).to eq("lt5")
    expect(json_body["evasion"]).to eq("before_classification" => 0, "after_classification" => 0)
  end

  # Módulo 32b (contrato §9, Q10, A30): o bloco `observation`, sobre o mesmo
  # recorte. Horas = último ended_at (ou agora) − primeiro started_at, uma casa
  # decimal (número JSON, como os minutos do `stay`); supressão do bloco inteiro
  # pelo número de estadias.
  describe "observation" do
    # Um encontro em atendimento, chegado em `base + index h`, com as estadias
    # dadas como [início, fim] em horas depois de `base` (fim nil = aberta).
    def observed_visit!(index, *spans, unit: upa)
      travel_to(base + index.hours)
      encounter = in_care_encounter!(unit)
      spans.each do |from, to|
        stay = UrgencyBedStay.create!(urgency_encounter: encounter, urgency_bed: urgency_bed!(unit), health_unit: unit,
                                      started_at: base + from.hours, started_by_user: doctor)
        stay.update!(ended_at: base + to.hours, end_kind: "observation_ended", ended_by_user: doctor) if to
      end
      encounter
    end

    def observation = json_body["observation"]

    it "6 encontros (2 acima de 24 h): mediana, p90 e horas-leito à mão; over_24h 1 a 4 vira lt5; a troca de leito soma as duas estadias" do
      observed_visit!(0, [ 0, 2 ])
      observed_visit!(1, [ 1, 6 ])
      observed_visit!(2, [ 2, 5 ], [ 6, 12 ]) # troca com intervalo: 10 h no encontro, 3 + 6 h de leito
      observed_visit!(3, [ 3, 23 ])
      observed_visit!(4, [ 4, 30.25 ])
      observed_visit!(5, [ 5, 35 ])
      read_dashboard!
      # horas: 2, 5, 10, 20, 26,25, 30 → mediana 15, p90 = 26,25 + 0,5 × 3,75
      expect(observation).to eq("stays" => 6, "over_24h" => "lt5", "median_hours" => 15.0, "p90_hours" => 28.1,
                                "bed_hours" => 92.3)
    end

    it "com 5 ou mais acima de 24 h, over_24h aparece" do
      5.times { |i| observed_visit!(i, [ i, i + 25 ]) }
      observed_visit!(5, [ 5, 7 ])
      read_dashboard!
      expect(observation).to include("stays" => 6, "over_24h" => 5)
    end

    it "3 encontros → o bloco inteiro lt5" do
      3.times { |i| observed_visit!(i, [ i, i + 30 ]) }
      read_dashboard!
      expect(observation).to eq("stays" => "lt5", "over_24h" => "lt5", "median_hours" => "lt5", "p90_hours" => "lt5",
                                "bed_hours" => "lt5")
    end

    it "nenhum encontro com estadia → zeros e medidas nulas" do
      in_care_encounter!(upa)
      read_dashboard!
      expect(observation).to eq("stays" => 0, "over_24h" => 0, "median_hours" => nil, "p90_hours" => nil, "bed_hours" => nil)
    end

    it "o registered_in_error, o outro mês e a outra UPA não contam" do
      5.times { |i| observed_visit!(i, [ i, i + 3 ]) }
      wrong = observed_visit!(6, [ 6, 9 ])
      travel_to(base + 10.hours)
      result = Urgency::RecordOutcome.call(encounter: wrong.reload, attrs: { "kind" => "registered_in_error", "reason" => "Duplicidade" },
                                           by: upa_reception!, team: nil)
      expect(result).to be_ok
      observed_visit!(7, [ 7, 10 ], unit: upa!(name: "UPA Norte"))
      read_dashboard!(month: "2026-10", health_unit_id: upa.id)
      expect(observation).to include("stays" => 5, "bed_hours" => 15.0)
    end

    it "a estadia aberta conta até agora" do
      5.times { |i| observed_visit!(i, [ i, i + 1 ]) }
      observed_visit!(5, [ 5, nil ])
      read_dashboard!
      # Lido em 5/11 10:00; a estadia abriu em 5/10 13:00 → 741 h; horas 1 ×5 e 741:
      # p90 = 1 + 0,5 × 740.
      expect(observation).to include("stays" => 6, "over_24h" => "lt5", "p90_hours" => 371.0)
    end
  end

  describe "acesso e parâmetros" do
    it "municipal_admin e analyst leem; o resto → 403 missing_role" do
      sign_in_as(staff_with("gestor-#{SecureRandom.hex(3)}@cidade.gov.br", "municipal_admin"))
      dashboard
      expect(response).to have_http_status(:ok)
      sign_in_as(reader)
      dashboard
      expect(response).to have_http_status(:ok)
      [ doctor, nurse, upa_reception! ].each do |user|
        sign_in_as(user)
        dashboard
        expect(response).to have_http_status(:forbidden)
        expect(json_body).to eq("error" => "missing_role")
      end
    end

    it "mês padrão = o corrente; formato inválido ou futuro → 422 month; unidade fora das UPAs ativas → 422" do
      travel_to(Time.zone.local(2026, 11, 5, 10, 0))
      sign_in_as(reader)
      dashboard({})
      expect(json_body["month"]).to eq("2026-11")
      [ "2026-13", "11/2026", "2026-12" ].each do |month|
        dashboard(month: month)
        expect(response).to have_http_status(:unprocessable_content)
        expect(json_body).to include("error" => "invalid_request", "path" => "month")
      end
      [ create_unit("UBS Centro").id, upa!(name: "UPA Inativa").tap { |u| u.update!(active: false) }.id, "x" ].each do |id|
        dashboard(month: "2026-10", health_unit_id: id)
        expect(response).to have_http_status(:unprocessable_content)
        expect(json_body).to include("error" => "invalid_request", "path" => "health_unit_id")
      end
      dashboard(month: "2026-10", cpf: "x")
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body["path"]).to eq("cpf")
    end

    it "urgency_care desligado → 403 feature_disabled" do
      Platform::Features.set!(city: city, key: Urgency::Gate::KEY, enabled: false, maintainer: ledi_maintainer!)
      CityCatalog.reset_cache!
      sign_in_as(reader)
      dashboard
      expect(response).to have_http_status(:forbidden)
      expect(json_body).to eq("error" => "feature_disabled", "feature" => "urgency_care")
    end
  end
end
