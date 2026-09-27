require "rails_helper"

# Módulo 09, critério de fechamento (ADR 0018): só o municipal_admin escreve
# unidade; desativação com atendimento ou pedido aberto é recusada; unidade
# inativa não recebe check-in nem encaminhamento — inclusive quando a
# desativação chega entre a leitura e a transação do comando.
RSpec.describe "Invariantes das unidades (ADR 0018)", type: :request do
  before { Current.city = TEST_CITY_A; Rails.cache.clear }
  after { Current.reset }

  let(:admin) { staff_with("admin@cidade.gov.br", "municipal_admin") }
  let(:reception) { staff_with("recepcao@cidade.gov.br", "citizen_verifier") }
  let(:doctor) { staff_with("medica@cidade.gov.br", "health_professional") }
  let(:citizen) { Citizen.create!(cpf: "52998224725", phone: "+5541998765432") }
  let(:unit) { create_unit }
  let(:reason) { "cidadão sem celular" }

  describe "só o municipal_admin escreve unidade" do
    (Membership::ROLES - %w[municipal_admin]).each do |role|
      it "#{role}: 403 em /units/all e em todas as escritas, nada muda" do
        target = create_unit("UBS Ativa")
        sign_in_as(staff_with("#{role}@cidade.gov.br", role))

        get "/attendance/units/all"
        expect(response).to have_http_status(:forbidden)
        [
          [ "/attendance/units", { name: "UBS Nova", kind: "ubs" } ],
          [ "/attendance/units/#{target.id}", { name: "UBS Outra", kind: "upa" } ],
          [ "/attendance/units/#{target.id}/deactivate", {} ],
          [ "/attendance/units/#{target.id}/activate", {} ]
        ].each do |path, params|
          json_post path, **params
          expect(response).to have_http_status(:forbidden), "#{role} POST #{path}"
        end
        expect(HealthUnit.sole).to have_attributes(name: "UBS Ativa", kind: "ubs", active: true)
      end
    end

    it "o municipal_admin passa (controle positivo)" do
      target = create_unit("UBS Ativa")
      sign_in_as(admin)
      json_post "/attendance/units/#{target.id}/deactivate"
      expect(response).to have_http_status(:ok)
      expect(target.reload.active).to be(false)
    end
  end

  describe "desativação com trabalho aberto é recusada" do
    it "atendimento aberto: 409 e a unidade continua ativa" do
      waiting_attendance(citizen, unit: unit, by: reception)
      sign_in_as(admin)
      json_post "/attendance/units/#{unit.id}/deactivate"
      expect(response).to have_http_status(:conflict)
      expect(JSON.parse(response.body)["error"]).to eq("unit_has_open_attendances")
      expect(unit.reload.active).to be(true)
    end

    it "pedido de agendamento vivo: 409 e a unidade continua ativa" do
      a = in_care!(waiting_attendance(citizen, unit: unit, by: reception), by: doctor)
      Attendances::Close.call(attendance: a, outcome: "return", referral_unit_id: nil, referral_note: nil, by: doctor)
      sign_in_as(admin)
      json_post "/attendance/units/#{unit.id}/deactivate"
      expect(response).to have_http_status(:conflict)
      expect(JSON.parse(response.body)["error"]).to eq("unit_has_open_requests")
      expect(unit.reload.active).to be(true)
    end
  end

  describe "unidade inativa não recebe check-in nem encaminhamento" do
    def check_in_by_code
      triage = completed_web_triage_for(citizen)
      code = Citizens::IssueCheckInCode.call(citizen: citizen, triage: triage).payload.fetch(:code)
      -> { Attendances::CheckIn.call(cpf: citizen.cpf, code: code, health_unit_id: unit.id, document_checked: false, by: reception) }
    end

    def check_in_by_exception
      triage = completed_web_triage_for(citizen)
      -> { Attendances::CheckInByException.call(cpf: citizen.cpf, triage_id: triage.id, health_unit_id: unit.id, reason: reason, by: reception) }
    end

    it "check-in por código e por exceção: invalid_unit, nenhum atendimento" do
      by_code = check_in_by_code
      by_exception = check_in_by_exception
      unit.update!(active: false)
      expect(by_code.call.reason).to eq(:invalid_unit)
      expect(by_exception.call.reason).to eq(:invalid_unit)
      expect(Attendance.count).to eq(0)
    end

    it "desativada entre a leitura e a transação: os dois check-ins recusam" do
      by_code = check_in_by_code
      by_exception = check_in_by_exception
      deactivate_before_transaction(unit)
      expect(by_code.call.reason).to eq(:invalid_unit)
      expect(by_exception.call.reason).to eq(:invalid_unit)
      expect(Attendance.count).to eq(0)
    end

    it "encaminhamento para unidade desativada entre a leitura e a transação: recusado, nada fecha" do
      upa = create_unit("UPA Norte", kind: "upa")
      a = in_care!(waiting_attendance(citizen, unit: unit, by: reception), by: doctor)
      deactivate_before_transaction(upa)
      result = Attendances::Close.call(attendance: a, outcome: "referred", referral_unit_id: upa.id,
                                       referral_note: nil, by: doctor)
      expect(result.reason).to eq(:invalid_unit)
      expect(a.reload).to be_open
      expect(AppointmentRequest.count).to eq(0)
    end
  end
end
