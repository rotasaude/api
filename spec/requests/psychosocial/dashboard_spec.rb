require "rails_helper"

# Módulo 31 (contrato §11, P11, P14, P46): painel do CAPS — só contagens.
# Valor de 1 a 4 sai "lt5" (string; as somas de noites e leitos-dia também),
# 0 sai 0. Lê a coordenação lotada, municipal_admin e analyst; sem trilha; nada
# nominal. Relógio fixo (18/11/2026, 15:00 locais).
RSpec.describe "CAPS — painel", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  around { |example| travel_to(Time.zone.local(2026, 11, 18, 15, 0)) { example.run } }

  let!(:city) { psychosocial_city! }
  let(:caps) { caps!(modality: "caps_ii", name: "CAPS II Boa Vista") }
  let(:lead) { caps_staff!(caps, cbo: "223505", lead: true) }
  let(:month) { Date.new(2026, 11, 1) }

  def dashboard(params = {}) = get("/psychosocial/dashboard", params: params)
  def reader(role) = staff_with("#{role}-#{SecureRandom.hex(3)}@cidade.gov.br", role)
  def active_in(unit = caps) = json_body["enrollments_active"].find { |row| row["health_unit_id"] == unit.id }

  def enrolled!(count, unit: caps, **over)
    Array.new(count) { enrollment!(unit, reference: lead, **over) }
  end

  def close!(enrollment, on:, destination: "01")
    enrollment.update!(closed_on: on, destination: destination, closed_by_user: lead)
  end

  describe "contagens e supressão (P11)" do
    before { sign_in_as(lead) }

    it "3 matrículas ativas → \"lt5\" (string); 5 → 5; nenhuma → 0" do
      dashboard
      expect(active_in).to eq("health_unit_id" => caps.id, "name" => "CAPS II Boa Vista", "caps_modality" => "caps_ii", "count" => 0)

      enrolled!(3)
      dashboard
      expect(response).to have_http_status(:ok)
      expect(active_in["count"]).to eq("lt5")
      expect(json_body["new_in_month"]).to eq("lt5")

      enrolled!(2)
      dashboard
      expect(active_in["count"]).to eq(5)
      expect(json_body["new_in_month"]).to eq(5)
    end

    it "a supressão é por CAPS: 4 → \"lt5\" e 6 → 6 no outro; ordenados pelo nome" do
      other = caps!(modality: "caps_i", name: "CAPS I Norte")
      link_professional!(lead, other, cbo: "223505")
      enrolled!(4)
      enrolled!(6, unit: other)
      dashboard
      expect(active_in["count"]).to eq("lt5")
      expect(active_in(other)["count"]).to eq(6)
      expect(json_body["enrollments_active"].map { |row| row["name"] }).to eq([ "CAPS I Norte", "CAPS II Boa Vista" ])
    end

    it "novas no mês e encerradas por destino (todo código da lista; o rótulo vem de options), por mês" do
      enrolled!(2, started_on: Date.new(2026, 10, 5)).each_with_index { |e, i| close!(e, on: Date.new(2026, 11, 3 + i), destination: "01") }
      enrolled!(5, started_on: Date.new(2026, 11, 2)).each { |e| close!(e, on: Date.new(2026, 11, 10), destination: "03") }
      close!(enrolled!(1, started_on: Date.new(2026, 10, 5)).first, on: Date.new(2026, 10, 20), destination: "05")

      dashboard(month: "2026-11")
      expect(json_body["new_in_month"]).to eq(5)
      expect(json_body["closed_by_destination"]).to eq(
        "01" => "lt5", "02" => 0, "03" => 5, "04" => 0, "05" => 0, "06" => 0, "07" => 0
      )
      expect(active_in["count"]).to eq(0) # todas já encerradas em 18/11

      dashboard(month: "2026-10")
      expect(json_body["new_in_month"]).to eq("lt5") # as 3 de 5/10
      expect(json_body["closed_by_destination"]).to include("05" => "lt5", "01" => 0, "03" => 0)
      expect(active_in["count"]).to eq("lt5") # em 31/10 só as duas que fecham em novembro estavam abertas
    end

    it "encerrada no último dia do mês já não é ativa no fim dele e conta como encerrada nesse mês, não no seguinte" do
      enrolled!(5, started_on: Date.new(2026, 10, 5))
      close!(enrolled!(1, started_on: Date.new(2026, 10, 5)).first, on: Date.new(2026, 10, 31), destination: "04")
      dashboard(month: "2026-10")
      expect(active_in["count"]).to eq(5)
      expect(json_body["closed_by_destination"]).to include("04" => "lt5")
      dashboard(month: "2026-11")
      expect(active_in["count"]).to eq(5)
      expect(json_body["closed_by_destination"]).to include("04" => 0)
      expect(json_body["new_in_month"]).to eq(0)
    end

    it "encerrada hoje, no mês corrente, já não é ativa (aberta agora) e conta como encerrada" do
      enrolled!(5, started_on: Date.new(2026, 10, 5))
      close!(enrolled!(1, started_on: Date.new(2026, 10, 5)).first, on: Date.new(2026, 11, 18), destination: "06")
      dashboard
      expect(active_in["count"]).to eq(5)
      expect(json_body["closed_by_destination"]).to include("06" => "lt5")
    end

    it "ações do mês por instrumento: as canceladas e as de outro mês ficam fora" do
      staff = caps_staff!(caps)
      e = enrolled!(1).first
      6.times { record_action!(caps, staff, participants: [ { enrollment_id: e.id } ]) }
      3.times { record_action!(caps, staff, sigtap_code: "0301080259") }
      record_action!(caps, staff, sigtap_code: "0301080259", performed_at: Time.zone.local(2026, 10, 20, 10))
      cancelled = record_action!(caps, staff, participants: [ { enrollment_id: e.id } ])
      Psychosocial::CancelAction.call(action: cancelled, reason: "Lançada em duplicidade no dia", by: staff)

      dashboard
      expect(json_body["actions_by_instrument"]).to eq("raas_psi" => 6, "bpa_c" => "lt5", "bpa_i" => 0)
      dashboard(month: "2026-10")
      expect(json_body["actions_by_instrument"]).to eq("raas_psi" => 0, "bpa_c" => "lt5", "bpa_i" => 0)
    end

    it "PTS vencidos: vale só a versão mais nova, e a matrícula sem PTS vence após 90 dias" do
      plans = enrolled!(6)
      plans.each do |e|
        PsychosocialCarePlan.create!(psychosocial_enrollment: e, version: 1, needs: "x", goals: [], intensity: "intensive",
                                     review_on: Date.new(2026, 11, 1), created_by_user: lead)
      end
      PsychosocialCarePlan.create!(psychosocial_enrollment: plans.first, version: 2, needs: "x", goals: [], intensity: "intensive",
                                   review_on: Date.new(2027, 1, 1), created_by_user: lead) # a mais nova está em dia
      enrolled!(1, started_on: Date.new(2026, 7, 1)) # sem PTS há mais de 90 dias
      enrolled!(1)                                   # sem PTS, recém-chegada: em dia
      dashboard
      expect(json_body["care_plans_overdue"]).to eq(6) # 5 com a revisão vencida + 1 sem PTS antiga
    end

    it "RAAS do mês por estado e o aviso no_actions (P14: aviso, não bloqueio)" do
      staff = caps_staff!(caps)
      all = enrolled!(9)
      all.first(5).each { |e| record_action!(caps, staff, participants: [ { enrollment_id: e.id } ]) }
      PsychosocialMonthlyRecord.where(psychosocial_enrollment_id: all[0, 2].map(&:id)).update_all(status: "closed", snapshot: "foto")
      PsychosocialMonthlyRecord.where(psychosocial_enrollment_id: all[2].id).update_all(status: "exported", snapshot: "foto")
      dashboard
      expect(json_body["raas_month"]).to eq("open" => 6, "closed" => "lt5", "exported" => "lt5", "no_actions" => "lt5")
      dashboard(month: "2026-10")
      expect(json_body["raas_month"]).to eq("open" => 0, "closed" => 0, "exported" => 0, "no_actions" => 0)
    end
  end

  describe "ocupação dos leitos" do
    let(:night) { caps!(modality: "caps_ad_iii", name: "CAPS AD III Centro Vida") }
    let(:tech) { caps_staff!(night, cbo: "322205") }
    let!(:l1) { bed!(night, label: "L1") }
    let!(:l2) { bed!(night, label: "L2") }

    def stay!(bed, enrollment, from, to, open: false)
      attrs = { psychosocial_bed: bed, health_unit: night, psychosocial_enrollment: enrollment, patient_id: enrollment.patient_id,
                started_at: from, expected_end_at: to, started_by_user: tech }
      attrs.merge!(ended_at: to, end_reason: "Alta do leito", closed_by_user: tech) unless open
      PsychosocialNightStay.create!(attrs)
    end

    before do
      bed!(night, label: "L3").update!(active: false)
      link_professional!(lead, night, cbo: "223505")
      sign_in_as(lead)
    end

    it "noites do mês (a noite que vira o mês conta só em novembro; a aberta conta até hoje) e leitos-dia dos leitos ativos" do
      a, b, c = Array.new(3) { enrollment!(night, reference: tech, started_on: Date.new(2026, 10, 1)) }
      stay!(l1, a, Time.zone.local(2026, 10, 30, 22), Time.zone.local(2026, 11, 2, 8))   # 30/10, 31/10, 01/11 → 1 em novembro
      stay!(l1, b, Time.zone.local(2026, 11, 3, 10), Time.zone.local(2026, 11, 9, 10))   # 6 noites
      stay!(l2, c, Time.zone.local(2026, 11, 15, 10), Time.zone.local(2026, 11, 20, 10), open: true) # 15..18: 4 noites até hoje
      dashboard(health_unit_id: night.id)
      expect(response).to have_http_status(:ok)
      # 1 + 6 + 4 = 11 noites; 2 leitos ativos × 18 dias (1º a 18/11) = 36 leitos-dia
      expect(json_body["bed_occupancy"]).to eq("nights" => 11, "bed_days" => 36)

      dashboard(health_unit_id: night.id, month: "2026-10")
      expect(json_body["bed_occupancy"]["nights"]).to eq("lt5") # só a de 30 e 31/10: 2 noites
      expect(json_body["bed_occupancy"]["bed_days"]).to eq(62)
    end

    it "a noite de hoje conta igual dentro do previsto e além dele (permanência aberta que passou do previsto)" do
      b, c = Array.new(2) { enrollment!(night, reference: tech, started_on: Date.new(2026, 11, 1)) }
      stay!(l1, b, Time.zone.local(2026, 11, 3, 10), Time.zone.local(2026, 11, 9, 10))                # 6 noites (3..8)
      stay!(l2, c, Time.zone.local(2026, 11, 15, 10), Time.zone.local(2026, 11, 16, 10), open: true)  # previsto 15/11; hoje é 18: 15..18 = 4
      dashboard(health_unit_id: night.id)
      expect(json_body["bed_occupancy"]).to eq("nights" => 10, "bed_days" => 36)
    end

    it "CAPS sem acolhimento noturno não tem ocupação" do
      dashboard(health_unit_id: caps.id)
      expect(json_body["bed_occupancy"]).to eq("nights" => 0, "bed_days" => 0)
    end
  end

  describe "quem lê" do
    it "municipal_admin e analyst leem todos os CAPS, com health_unit_id opcional" do
      other = caps!(modality: "caps_i", name: "CAPS I Norte")
      enrolled!(6)
      enrolled!(5, unit: other)
      %w[municipal_admin analyst].each do |role|
        sign_in_as(reader(role))
        dashboard
        expect(response).to have_http_status(:ok)
        expect(json_body["enrollments_active"].map { |row| row["count"] }).to eq([ 5, 6 ])
        expect(json_body["new_in_month"]).to eq(11)

        dashboard(health_unit_id: other.id)
        expect(json_body["enrollments_active"].map { |row| row["name"] }).to eq([ "CAPS I Norte" ])
        expect(json_body["new_in_month"]).to eq(5)
      end
    end

    it "a coordenação lê só os CAPS em que está lotada" do
      other = caps!(modality: "caps_i", name: "CAPS I Norte")
      enrolled!(1, unit: other)
      enrolled!(2)
      sign_in_as(lead)
      dashboard
      expect(json_body["enrollments_active"].map { |row| row["name"] }).to eq([ "CAPS II Boa Vista" ])
      expect(json_body["new_in_month"]).to eq("lt5")

      dashboard(health_unit_id: other.id)
      expect(response).to have_http_status(:forbidden)
      expect(json_body).to eq("error" => "not_on_caps_team")
    end

    it "a coordenação sem lotação alguma recebe o painel zerado" do
      sign_in_as(step_up_enrolled!(staff_with("lead-sem-vinculo@cidade.gov.br", "psychosocial_lead")))
      dashboard
      expect(response).to have_http_status(:ok)
      expect(json_body["enrollments_active"]).to eq([])
      expect(json_body["new_in_month"]).to eq(0)
    end

    it "psychosocial_staff, billing_clerk e médico da UBS → 403 missing_role" do
      [ caps_staff!(caps), reader("billing_clerk"), ubs_doctor!(caps) ].each do |user|
        sign_in_as(user)
        dashboard
        expect(response).to have_http_status(:forbidden)
        expect(json_body).to eq("error" => "missing_role")
      end
    end

    it "sem sessão → 401; interruptor desligado → 403 feature_disabled" do
      dashboard
      expect(response).to have_http_status(:unauthorized)
      sign_in_as(lead)
      Platform::Features.set!(city: city, key: "psychosocial_care", enabled: false, maintainer: ledi_maintainer!)
      dashboard
      expect(response).to have_http_status(:forbidden)
      expect(json_body).to eq("error" => "feature_disabled", "feature" => "psychosocial_care")
    end
  end

  describe "mês e filtros" do
    before { sign_in_as(lead) }

    it "mês padrão = o corrente; formato inválido ou futuro → 422 invalid_request month" do
      dashboard
      expect(json_body["month"]).to eq("2026-11")
      [ "2026-13", "2026-1", "novembro", "2026-12", "2027-01" ].each do |bad|
        dashboard(month: bad)
        expect(response).to have_http_status(:unprocessable_entity)
        expect(json_body).to include("error" => "invalid_request", "path" => "month")
      end
    end

    it "health_unit_id malformado, inexistente ou de CAPS inativo → 422; chave desconhecida na query → 422" do
      [ "x", SecureRandom.uuid, caps!(modality: "caps_i").tap { |u| u.update!(active: false) }.id ].each do |id|
        dashboard(health_unit_id: id)
        expect(response).to have_http_status(:unprocessable_entity)
        expect(json_body).to include("error" => "invalid_request", "path" => "health_unit_id")
      end
      dashboard(q: "Renato")
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body["path"]).to eq("q")
    end
  end

  describe "sigilo (P46)" do
    it "nada nominal: sem nome, CPF, CNS, CID, substância nem id de paciente ou de matrícula; sem trilha nem evento" do
      patient = caps_patient!
      e = enrollment!(caps, patient: patient, reference: lead, cid: "F142")
      PsychosocialCarePlan.create!(psychosocial_enrollment: e, version: 1, needs: "Isolamento social", goals: [ "Voltar ao trabalho" ],
                                   intensity: "intensive", review_on: Date.new(2026, 11, 1), created_by_user: lead)
      record_action!(caps, caps_staff!(caps), participants: [ { enrollment_id: e.id } ])
      sign_in_as(lead)
      expect { dashboard }.not_to(change { [ DomainEvent.count, PsychosocialEnrollment.count ] })
      expect(response).to have_http_status(:ok)

      body = response.body
      forbidden = [ patient.full_name, patient.full_name.split.first, patient.cpf, patient.cns, patient.id, e.id, "F142", "Isolamento", "Voltar ao trabalho" ]
      forbidden.compact.each { |text| expect(body).not_to include(text.to_s) }
      expect(body.gsub(/\h{8}-\h{4}-\h{4}-\h{4}-\h{12}/, "")).not_to match(/\d{11}/) # CPF e CNS nunca por forma
      expect(body).to include("CAPS II Boa Vista") # P46: o painel por unidade mostra o CAPS pelo nome
      expect(DomainEvent.where(name: "clinical_record.viewed")).to be_empty
    end

    it "só as chaves previstas (sem lista de pacientes) para todos os papéis" do
      enrolled!(6)
      %w[municipal_admin analyst].each do |role|
        sign_in_as(reader(role))
        dashboard
        expect(json_body.keys).to eq(%w[month enrollments_active new_in_month closed_by_destination care_plans_overdue
                                        actions_by_instrument bed_occupancy raas_month])
        expect(json_body["enrollments_active"].first.keys).to eq(%w[health_unit_id name caps_modality count])
      end
    end
  end
end
