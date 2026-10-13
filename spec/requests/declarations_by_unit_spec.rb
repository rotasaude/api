require "rails_helper"

# api#59 (rodada especial do 19; decisão do usuário 2026-10-13): a declaração de
# comparecimento é da unidade escolhida no seletor (health_unit_id). A recepção
# da unidade lista, reimprime e cancela as declarações dos atendimentos dela —
# inclusive as de colegas. Não há vínculo de recepção com unidade no modelo:
# a unidade vem da tela (não é trava de segurança, é guarda contra engano).
RSpec.describe "Declarações por unidade", type: :request do
  before { documents_city!; ciap2_release!; cid10_release!; sigtap_release! }

  let(:unit) { create_unit }
  let(:other_unit) { create_unit("UBS Norte") }
  let(:doctor) { doctor!(unit) }
  let(:consultation) { finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1)) }
  let(:attendance) { consultation.attendance }
  let(:colleague) { staff_with("recepcao-#{SecureRandom.hex(3)}@cidade.gov.br", "citizen_verifier") }

  def declare!(by: verifier!, unit_id: unit.id)
    sign_in_as(by)
    json_post "/attendance/attendances/#{attendance.id}/declarations", content: { issuer_registration: "4471" }, health_unit_id: unit_id
    json_body
  end

  def viewed = DomainEvent.where(name: "clinical_record.viewed")

  describe "emissão" do
    it "com a unidade do atendimento emite; sem unidade ou com outra, 422 attendance_outside_unit" do
      expect(declare!).to include("kind" => "attendance_declaration")
      expect(response).to have_http_status(:created)
      declare!(unit_id: nil)
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "attendance_outside_unit" } ])
      declare!(unit_id: other_unit.id)
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "attendance_outside_unit" } ])
    end

    it "profissional com o seletor na própria unidade, que não é a do atendimento: 422" do
      declare!(by: doctor!(other_unit), unit_id: other_unit.id)
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "attendance_outside_unit" } ])
    end
  end

  describe "listas" do
    it "do atendimento: as da autora e das colegas, só metadados; a lista registra a leitura (spec §7)" do
      mine = declare!
      theirs = declare!(by: colleague)
      reader = verifier!
      sign_in_as(reader)
      expect { get "/attendance/attendances/#{attendance.id}/declarations", params: { health_unit_id: unit.id } }.to(change { viewed.count }.by(2))
      expect(viewed.last.payload).to include("access" => "declaration_list", "user_id" => reader.id, "patient_id" => consultation.patient.id)
      expect(response).to have_http_status(:ok)
      rows = json_body["items"]
      expect(rows.map { |row| row["id"] }).to contain_exactly(mine["id"], theirs["id"])
      expect(rows.first.keys).to contain_exactly("id", "status", "issued_at", "cancelled_at", "short_code", "attendance_id", "author", "patient")
      expect(rows.first["patient"]).to eq("display_name" => attendance.citizen.display_name)

      get "/attendance/attendances/#{attendance.id}/declarations", params: { health_unit_id: other_unit.id }
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "attendance_outside_unit" } ])
    end

    it "do dia na unidade" do
      declare!
      other_consultation = finalized_consultation!(unit: other_unit, doctor: doctor!(other_unit), citizen: verified_citizen!(2))
      sign_in_as(verifier!)
      json_post "/attendance/attendances/#{other_consultation.attendance_id}/declarations", content: {}, health_unit_id: other_unit.id
      expect { get "/attendance/declarations", params: { health_unit_id: unit.id } }.to(change { viewed.count }.by(1))
      expect(json_body["items"].size).to eq(1)
      get "/attendance/declarations", params: { health_unit_id: unit.id, date: (Time.zone.today - 1).iso8601 }
      expect(json_body["items"]).to eq([])
      get "/attendance/declarations", params: {}
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "attendance_outside_unit" } ])
    end
  end

  describe "leitura e impressão pela colega da recepção" do
    it "com a unidade certa imprime e deixa trilha unit_reception; com outra, 403" do
      id = declare!["id"]
      sign_in_as(colleague)
      get "/attendance/documents/#{id}/print", params: { health_unit_id: unit.id }
      expect([ response.status, response.media_type ]).to eq([ 200, "application/pdf" ])
      expect(viewed.last.payload).to include("access" => "unit_reception", "user_id" => colleague.id)
      get "/attendance/documents/#{id}/print", params: { health_unit_id: other_unit.id }
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "cancelamento" do
    it "a colega da recepção, com step-up e a unidade certa, cancela; com outra unidade, 422" do
      id = declare!["id"]
      stepped_up!(colleague)
      json_post "/attendance/documents/#{id}/cancel", reason: "Horário de chegada errado", health_unit_id: other_unit.id
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "attendance_outside_unit" } ])
      json_post "/attendance/documents/#{id}/cancel", reason: "Horário de chegada errado", health_unit_id: unit.id
      expect([ response.status, json_body["status"] ]).to eq([ 200, "cancelled" ])
      get "/attendance/documents/#{id}/print", params: { health_unit_id: unit.id }
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "already_cancelled" } ])
    end

    it "a recepção não cancela atestado, nem com a unidade certa" do
      sick_note = ClinicalDocuments::Issue.call(kind: "sick_note", content: { "type" => "leave", "days" => 2 },
                                                by: doctor, consultation: consultation).payload[:document]
      stepped_up!(colleague)
      json_post "/attendance/documents/#{sick_note.id}/cancel", reason: "Dias errados no atestado", health_unit_id: unit.id
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "not_author" } ])
    end
  end
end
