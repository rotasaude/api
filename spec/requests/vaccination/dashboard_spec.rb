require "rails_helper"

# Módulo 29, Task 20 (ADR 0047; contrato §15 V8, V14 = D13 do dashboard):
# painel da vacinação. Só contagens, sem nome nem CPF, sem trilha.
RSpec.describe "Sala de vacina — painel", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let!(:city) { vaccination_city!(rnds: true) }
  let(:room_a) { vaccine_room! }
  let(:room_b) { vaccine_room! }
  let(:vaccinator_a) { room_member!(room_a) }
  let(:vaccinator_b) { room_member!(room_b) }
  let(:analyst) { staff_with("analise-#{SecureRandom.hex(3)}@cidade.gov.br", "analyst") }
  let(:month) { Time.zone.today.strftime("%Y-%m") }
  let(:path) { "/vaccination/dashboard" }

  def doses!(room, vaccinator, count, code: "42", **over)
    lot = vaccine_lot!(room, code: code, doses: count + 1)
    Array.new(count) { create_immunization!(room, vaccinator_user: vaccinator, stock_lot: lot, immunobiological_code: code, **over) }
  end

  def loss!(lot, kind, quantity, at)
    adjustment = StockAdjustment.create!(stock_location: room_a.stock_location, stock_lot: lot, kind: kind, status: "applied", loss_code: ("broken" if kind == "loss"),
                                         quantity: quantity, balance_at_request: 40, reason: "Frasco quebrado na sala", requested_by_user: pharmacy_admin!)
    StockMovement.create!(stock_location: room_a.stock_location, stock_lot: lot, stock_adjustment: adjustment, immunobiological_code: "22", kind: kind,
                          quantity: quantity, reason: "Frasco quebrado na sala", recorded_by_user: pharmacy_admin!, recorded_at: at)
  end

  def row(code, room) = json_body["doses_by_immunobiological"].find { |r| r.dig("immunobiological", "code") == code && r.dig("room", "id") == room.id }

  context "acesso" do
    it "municipal_admin e analyst leem; vacinador 403; sem sessão 401; desligado 403" do
      get path
      expect(response).to have_http_status(:unauthorized)
      sign_in_as(vaccinator_a)
      get path
      expect(response).to have_http_status(:forbidden)
      sign_in_as(pharmacy_admin!)
      get path
      expect(response).to have_http_status(:ok)
      sign_in_as(analyst)
      get path
      expect(response).to have_http_status(:ok)
      Platform::Features.set!(city: city, key: "vaccination", enabled: false, maintainer: ledi_maintainer!)
      get path
      expect(response).to have_http_status(:forbidden)
      expect(json_body).to include("error" => "feature_disabled")
    end
  end

  context "parâmetros" do
    before { sign_in_as(analyst) }

    it "mês inválido → 422; unidade malformada → 422; inexistente → 404; chave desconhecida → 422" do
      [ "2026-13", "abc", "", "2026-1" ].each do |bad|
        get path, params: { month: bad }
        expect(response).to have_http_status(:unprocessable_entity)
        expect(json_body).to include("path" => "month")
      end
      get path, params: { health_unit_id: "x" }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body).to include("path" => "health_unit_id")
      get path, params: { health_unit_id: SecureRandom.uuid }
      expect(response).to have_http_status(:not_found)
      get path, params: { cpf: "1" }
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "sem mês usa o corrente" do
      get path
      expect(json_body["month"]).to eq(month)
    end
  end

  context "contagens" do
    before { sign_in_as(analyst) }

    it "doses por imunobiológico e sala: mês, ativas e não transcritas; 1 a 4 suprimido; filtro por unidade" do
      doses!(room_a, vaccinator_a, 5)
      doses!(room_b, vaccinator_b, 6)
      doses!(room_a, vaccinator_a, 2, code: "22")
      doses!(room_a, vaccinator_a, 1, applied_at: 2.months.ago)
      doses!(room_a, vaccinator_a, 1, transcription: true, vaccine_room: room_a, stock_lot: nil)
      doses!(room_a, vaccinator_a, 1, cancelled_at: Time.current, cancelled_by_user: room_member!(room_a, role: "room_lead", cbo: "223505"),
                                      cancel_reason: "Paciente errado na busca")
      get path, params: { month: month }
      expect(response).to have_http_status(:ok)
      expect(row("42", room_a)).to eq("immunobiological" => { "code" => "42", "name" => "Vacina penta (DTP/HB/Hib)" },
                                      "room" => { "id" => room_a.id, "name" => room_a.name }, "count" => 5)
      expect(row("42", room_b)["count"]).to eq(6)
      expect(row("22", room_a)["count"]).to be_nil
      expect(json_body["suppressed"]).to be(true)

      get path, params: { month: month, health_unit_id: room_b.health_unit_id }
      expect(json_body["doses_by_immunobiological"].map { |r| r.dig("room", "id") }.uniq).to eq([ room_b.id ])
    end

    it "rnds: pending, blocked, rejected e late; envio desligado → pending e late de pending zerados" do
      def entry_for(hours, status: "pending", **attrs)
        dose = travel_to(hours.hours.ago) { record!(room_a, vaccine_patient!(birth_date: Time.zone.today - 61), by: vaccinator_a, applied_at: Time.current.iso8601) }
        RndsOutboxEntry.find_by(immunization_id: dose.id, kind: "application").update!(status: status, **attrs) unless status == "pending" && attrs.empty?
      end
      entry_for(25)
      entry_for(2)
      entry_for(1, status: "blocked", block_reason: "patient_without_cns_or_cpf")
      entry_for(3, status: "rejected", error: "Recusada")
      get path
      expect(json_body["rnds"]).to eq("pending" => 2, "blocked" => 1, "rejected" => 1, "late" => 1)

      get path, params: { health_unit_id: room_b.health_unit_id }
      expect(json_body["rnds"]).to eq("pending" => 0, "blocked" => 0, "rejected" => 0, "late" => 0)

      Platform::Features.set!(city: city, key: "rnds_immunization", enabled: false, maintainer: ledi_maintainer!)
      get path
      expect(json_body["rnds"]).to eq("pending" => 0, "blocked" => 1, "rejected" => 1, "late" => 0)
    end

    it "perdas do mês: técnica (frascos fechados) e física (movimento; a pendente não conta)" do
      lot = vaccine_lot!(room_a, code: "22", doses: 50)
      vial = open_vial!(room_a, lot: lot, by: vaccinator_a)
      vial.update_columns(closed_at: Time.current, closed_by_user_id: vaccinator_a.id, close_reason: "Fim do dia, descarte", technical_loss_doses: 7)
      loss!(lot, "loss", -3, Time.current)
      loss!(lot, "expiry", -2, Time.current)
      loss!(lot, "loss", -9, 2.months.ago)
      # Perda aguardando aprovação: sem movimento, não conta.
      StockAdjustment.create!(stock_location: room_a.stock_location, stock_lot: lot, kind: "loss", status: "pending", loss_code: "temperature_excursion",
                              quantity: -4, balance_at_request: 40, reason: "Excursão de temperatura", requested_by_user: pharmacy_admin!)
      get path, params: { month: month }
      expect(json_body["losses"]).to eq("technical" => 7, "physical" => 5)
      get path, params: { month: month, health_unit_id: room_b.health_unit_id }
      expect(json_body["losses"]).to eq("technical" => 0, "physical" => 0)
    end

    it "cadernetas sem conferência: pacientes com linha checked false" do
      one, two = Array.new(2) { vaccine_patient!(birth_date: Time.zone.today - 100) }
      [ [ one, "penta", false ], [ one, "vip", false ], [ two, "penta", true ] ].each do |patient, series, checked|
        VaccinationStatus.create!(patient: patient, series: series, immunobiological_code: "42", status: "due", age_months: 3,
                                  computed_on: Time.zone.today, checked: checked)
      end
      get path
      expect(json_body["unchecked_cards"]).to eq(1)
    end

    context "cobertura do C2 por equipe" do
      let(:team) { HealthTeam.create!(health_unit: room_a.health_unit, ine: format("%010d", SecureRandom.random_number(10**10)), kind: "70", name: "ESF Centro") }

      def children(*months) = months.map { |m| vaccine_patient!(birth_date: Time.zone.today.advance(months: -m)) }

      def stub_members(*patients, citizens: [])
        allow(CareLines::TeamPopulation).to receive(:members).and_call_original
        allow(CareLines::TeamPopulation).to receive(:members).with(team: team).and_return(patient_ids: patients.map(&:id), citizen_ids: citizens.map(&:id))
      end

      # Esquema do C2 fechado: 3 hexas, 2 SCR (a partir dos 12 meses) e 2 pneumo.
      def complete_c2!(patient)
        born = patient.birth_date.to_date
        { "43" => [ 2, 4, 6 ], "26" => [ 2, 4 ], "56" => [ 12, 14 ] }.each do |code, months|
          months.each do |m|
            create_immunization!(room_a, patient: patient, immunobiological_code: code, vaccinator_user: vaccinator_a, stock_lot: nil, vaccine_room: nil,
                                         transcription: true, applied_at: born.advance(months: m).in_time_zone + 10.hours)
          end
        end
      end

      it "elegíveis: 12 a 23 meses; completa: esquema fechado; 1 a 4 suprimido" do
        eligible = children(12, 15, 15, 20, 23)
        outside = children(11, 24)
        complete_c2!(eligible.first)
        stub_members(*eligible, *outside)
        sign_in_as(analyst)
        get path
        entry = json_body["c2_coverage_by_team"].find { |t| t.dig("team", "id") == team.id }
        expect(entry).to eq("team" => { "id" => team.id, "name" => "ESF Centro" }, "eligible" => 5, "complete" => nil)
      end

      it "cidadão sem paciente da população conta em eligible (12 a 23 meses) e nunca em complete" do
        patients = children(13, 14, 15, 16)
        inside = care_citizen!(age: 1, sex: "female")
        inside.update!(birth_date: Time.zone.today.advance(months: -18).iso8601)
        outside = care_citizen!(age: 1, sex: "female")
        outside.update!(birth_date: Time.zone.today.advance(months: -30).iso8601)
        stub_members(*patients, citizens: [ inside, outside ])
        allow(Vaccination::C2).to receive(:met_on).and_return(Time.zone.today)
        sign_in_as(analyst)
        get path
        entry = json_body["c2_coverage_by_team"].find { |t| t.dig("team", "id") == team.id }
        expect(entry).to include("eligible" => 5, "complete" => nil)
        expect(Vaccination::C2).to have_received(:met_on).exactly(4).times
      end

      it "completa visível com 5 ou mais; filtro por unidade; equipe de outra unidade fora" do
        eligible = children(13, 14, 15, 16, 17)
        stub_members(*eligible)
        allow(Vaccination::C2).to receive(:met_on).and_return(Time.zone.today)
        other_team = HealthTeam.create!(health_unit: room_b.health_unit, ine: format("%010d", SecureRandom.random_number(10**10)), kind: "70", name: "ESF Outra")
        sign_in_as(analyst)
        get path, params: { health_unit_id: room_a.health_unit_id }
        expect(json_body["c2_coverage_by_team"]).to eq([ { "team" => { "id" => team.id, "name" => "ESF Centro" }, "eligible" => 5, "complete" => 5 } ])
        get path
        expect(json_body["c2_coverage_by_team"].map { |t| t.dig("team", "id") }).to contain_exactly(team.id, other_team.id)
      end
    end

    it "nenhum nome, CPF ou CNS no JSON" do
      patient = vaccine_patient!(birth_date: Time.zone.today - 61)
      create_immunization!(room_a, patient: patient, vaccinator_user: vaccinator_a)
      get path
      expect(response.body).not_to include(patient.full_name, patient.cpf, patient.cns, patient.id)
    end
  end
end
