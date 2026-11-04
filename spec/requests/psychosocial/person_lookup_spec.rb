require "rails_helper"

# Módulo 31 (contrato §15 "Busca de paciente", P30): POST /psychosocial/person_lookup
# com CPF OU CNS (o usuário em situação de rua sem CPF), na forma do
# Vaccination::PersonLookupsController; duplicados em POST
# /psychosocial/patients/duplicates. Tudo no corpo; trilha por pessoa mostrada.
# Usam a equipe lotada num CAPS e o encaminhador da UBS.
RSpec.describe "CAPS — busca de paciente", type: :request do
  let!(:city) { psychosocial_city! }
  let(:caps) { caps! }
  let(:staff) { caps_staff!(caps) }
  let(:patient) { caps_patient! }
  let(:viewed) { DomainEvent.where(name: "clinical_record.viewed") }

  describe "POST /psychosocial/person_lookup" do
    it "pelo CPF ou pelo CNS, sem os identificadores inteiros, com trilha" do
      sign_in_as(staff)
      expect { json_post "/psychosocial/person_lookup", cpf: patient.cpf }.to change { viewed.count }.by(1)
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("patient_id" => patient.id, "display_name" => patient.display_name, "has_cpf" => true,
                                   "cns_masked" => patient.cns_masked)
      expect(response.body).not_to include(patient.cpf, patient.cns)
      expect(viewed.last.payload).to include("patient_id" => patient.id, "user_id" => staff.id, "access" => "psychosocial")

      json_post "/psychosocial/person_lookup", cns: patient.cns
      expect(json_body["patient_id"]).to eq(patient.id)
    end

    it "os dois, nenhum, chave estranha ou na query → 422; ninguém → 404" do
      sign_in_as(staff)
      json_post "/psychosocial/person_lookup", cpf: patient.cpf, cns: patient.cns
      expect([ response.status, json_body["path"] ]).to eq([ 422, "cns" ])
      json_post "/psychosocial/person_lookup", {}
      expect(json_body["path"]).to eq("cpf")
      json_post "/psychosocial/person_lookup", cpf: patient.cpf, name: "x"
      expect(json_body["path"]).to eq("name")
      post "/psychosocial/person_lookup?cpf=#{patient.cpf}", params: {}.to_json, headers: { "CONTENT_TYPE" => "application/json" }
      expect([ response.status, json_body["path"] ]).to eq([ 422, "cpf" ])
      json_post "/psychosocial/person_lookup", cns: Professionals::Cns.generate("ninguem")
      expect([ response.status, json_body["error"] ]).to eq([ 404, "person_not_found" ])
    end

    it "o encaminhador da UBS também busca; sem lotação nem vínculo de UBS → 403" do
      sign_in_as(ubs_doctor!(create_unit))
      json_post "/psychosocial/person_lookup", cpf: patient.cpf
      expect(response).to have_http_status(:ok)

      sign_in_as(staff_with("faturista-#{SecureRandom.hex(3)}@cidade.gov.br", "billing_clerk"))
      json_post "/psychosocial/person_lookup", cpf: patient.cpf
      expect([ response.status, json_body["error"] ]).to eq([ 403, "missing_role" ])
    end
  end

  describe "POST /psychosocial/patients/duplicates" do
    it "candidatos pelo nome e nascimento, com trilha por candidato" do
      sign_in_as(staff)
      expect do
        json_post "/psychosocial/patients/duplicates", full_name: patient.full_name, birth_date: patient.birth_date.to_s
      end.to change { viewed.count }.by(1)
      expect(json_body["candidates"].map { |c| c["patient_id"] }).to eq([ patient.id ])
      expect(json_body["candidates"].first.keys).to contain_exactly("patient_id", "display_name", "birth_date", "has_cpf")
    end

    it "sem nascimento válido ou com chave estranha → 422; sem papel → 403" do
      sign_in_as(staff)
      json_post "/psychosocial/patients/duplicates", full_name: "Maria", birth_date: "ontem"
      expect(json_body["path"]).to eq("birth_date")
      json_post "/psychosocial/patients/duplicates", full_name: "Maria", birth_date: "1980-01-01", cpf: "1"
      expect(json_body["path"]).to eq("cpf")

      sign_in_as(staff_with("analista-#{SecureRandom.hex(3)}@cidade.gov.br", "analyst"))
      json_post "/psychosocial/patients/duplicates", full_name: "Maria", birth_date: "1980-01-01"
      expect(response).to have_http_status(:forbidden)
    end
  end
end
