require "rails_helper"

# Módulo 31, fix round 2 da Task 14 (P46, P51): o detalhe para o qual a linha
# do tempo geral aponta não pode desfazer o rótulo genérico. A dose aplicada
# em sala de um CAPS (detalhe da imunização e caderneta da sala) e o pedido de
# exame aberto no CAPS saem com "Centro de Atenção Psicossocial" no lugar do
# nome da unidade e do nome livre da sala, para todos os leitores. Unidade que
# não é CAPS fica como estava.
RSpec.describe "CAPS — detalhes apontados pela linha do tempo geral", type: :request do
  let(:label) { "Centro de Atenção Psicossocial" }
  let(:hidden) { [ "Centro Vida", "AD III", "caps_ad_iii", "Sala Girassol" ] }
  let(:caps) do
    HealthUnit.create!(name: "CAPS AD III Centro Vida", kind: "caps", caps_modality: "caps_ad_iii", service_classification: "001",
                       cnes: "7654321")
  end
  let(:ubs) { create_unit("UBS Boa Vista") }
  let(:doctor) { doctor!(ubs) }

  def expect_hidden = hidden.each { |text| expect(response.body).not_to include(text) }

  describe "vacina em sala do CAPS" do
    let!(:city) { vaccination_city! }
    let(:patient) { exam_patient!(exam_seq!).first }
    let(:caps_room) do
      location = StockLocation.create!(kind: "vaccine_room", name: "Sala Girassol", health_unit: caps, updated_by_user: pharmacy_admin!)
      VaccineRoom.create!(health_unit: caps, stock_location: location, name: "Sala Girassol", updated_by_user: pharmacy_admin!)
    end
    let(:ubs_room) { vaccine_room!(ubs) }

    before { Platform::Features.set!(city: city, key: "patient_timeline", enabled: true, maintainer: ledi_maintainer!) }

    it "o médico da UBS em contexto abre o detalhe da dose: sala e unidade genéricas" do
      dose = create_immunization!(caps_room, patient: patient)
      in_context!(doctor, ubs, patient)
      sign_in_as(doctor)
      get "/vaccination/immunizations/#{dose.id}"
      expect(response).to have_http_status(:ok)
      expect(json_body["room"]).to eq("id" => caps_room.id, "name" => label, "health_unit" => { "id" => caps.id, "name" => label })
      expect_hidden
    end

    it "o vacinador da UBS lê a caderneta pela sala: a dose do CAPS genérica, a da UBS com o nome" do
      create_immunization!(caps_room, patient: patient)
      create_immunization!(ubs_room, patient: patient, immunobiological_code: "42", dose_code: "2", applied_at: 1.minute.ago)
      sign_in_as(room_member!(ubs_room))
      post "/vaccination/rooms/#{ubs_room.id}/card", params: { patient_id: patient.id }.to_json, headers: { "Content-Type" => "application/json" }
      expect(response).to have_http_status(:ok)
      rooms = json_body["immunizations"].map { |dose| dose["room"] }
      expect(rooms).to contain_exactly({ "id" => caps_room.id, "name" => label, "health_unit" => { "id" => caps.id, "name" => label } },
                                       { "id" => ubs_room.id, "name" => ubs_room.name, "health_unit" => { "id" => ubs.id, "name" => "UBS Boa Vista" } })
      expect_hidden
    end
  end

  describe "pedido de exame aberto no CAPS" do
    let!(:city) { exam_city! }
    let(:patient) { exam_patient!(exam_seq!).first }

    it "o médico da UBS em contexto lê o pedido: unidade genérica; o pedido da UBS mantém o nome" do
      caps_order = exam_order!(patient: patient, unit: caps, requester: doctor!(caps))
      ubs_order = exam_order!(patient: patient, unit: ubs, requester: doctor!(ubs))
      in_context!(doctor, ubs, patient)
      sign_in_as(doctor)
      get "/exams/orders/#{caps_order.id}"
      expect(response).to have_http_status(:ok)
      expect(json_body["unit"]).to eq("id" => caps.id, "name" => label)
      expect_hidden
      get "/exams/orders/#{ubs_order.id}"
      expect(json_body["unit"]).to eq("id" => ubs.id, "name" => "UBS Boa Vista")
    end
  end
end
