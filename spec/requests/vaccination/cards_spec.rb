require "rails_helper"

# Módulo 29, Task 5 (ADR 0047; contrato §2, §5; §15 V3, V14; Desvios 10, 11 e
# 20; Review Focus 2): a caderneta na sala, a conferência e a busca de pessoa.
# Leitura nominal com trilha `clinical_record.viewed` (access "vaccination"),
# uma por pessoa mostrada, só ids; CPF, CNS e nome só no corpo.
RSpec.describe "Sala de vacina — caderneta, conferência e busca de pessoa", type: :request do
  let!(:city) { vaccination_city! }
  let(:room) { vaccine_room! }
  let(:vaccinator) { room_member!(room) }
  let(:today) { Time.use_zone(city.time_zone) { Time.zone.today } }
  let(:json_headers) { { "Content-Type" => "application/json" } }

  def post_json(path, body, query: "") = post("#{path}#{query}", params: body.to_json, headers: json_headers)
  def card(body = {}, **fields) = post_json("/vaccination/rooms/#{room.id}/card", body.merge(fields))
  def check(body = {}, **fields) = post_json("/vaccination/rooms/#{room.id}/checks", body.merge(fields))
  def lookup(body = {}, query: "", **fields) = post_json("/vaccination/rooms/#{room.id}/person_lookup", body.merge(fields), query: query)
  def refusal(error, path) = { "error" => error, "path" => path, "problems" => [ { "path" => path, "error" => error } ] }
  def trail = DomainEvent.where(name: "clinical_record.viewed").order(:created_at, :id).map(&:payload).select { |p| p["access"] == "vaccination" }
  def go_live!(on) = VaccinationSetting.current.update!(go_live_on: on)
  def item(series_code, dose) = json_body["items"].find { |i| i["immunobiological"]["code"] == series_code && i["dose"]["code"] == dose }

  before { sign_in_as(vaccinator) }

  describe "POST /vaccination/rooms/:room_id/card" do
    # Review Focus 2: o caso mais comum no go-live.
    it "criança de 1 ano, caderneta não conferida, nenhuma dose: checked null, nenhum overdue, os passados unchecked; uma trilha" do
      go_live!(today - 30)
      child = vaccine_patient!(birth_date: today - 365, cpf: false)
      card(patient_id: child.id)
      expect(response).to have_http_status(:ok)
      expect(json_body["patient"]).to eq("id" => child.id, "display_name" => child.display_name, "birth_date" => child.birth_date,
                                         "sex" => "female", "has_cpf" => false, "cns_masked" => child.cns_masked)
      expect(json_body["checked"]).to be_nil
      expect(json_body["calendar_version"]).to eq("2026.1")
      statuses = json_body["items"].map { |i| i["status"] }
      expect(statuses).not_to include("overdue")
      expect(statuses).to include("unchecked")
      expect(item("42", "1")).to eq("immunobiological" => { "code" => "42", "name" => "Vacina penta (DTP/HB/Hib)" },
                                    "dose" => { "code" => "1", "name" => Vaccination::Terminologies.name("dose", "1") },
                                    "status" => "unchecked", "due_on" => (today - 305).iso8601, "applied" => nil)
      expect(json_body["immunizations"]).to eq([])
      expect(trail).to eq([ { "patient_id" => child.id, "user_id" => vaccinator.id, "access" => "vaccination", "reason_code" => nil,
                              "person_ref" => "patient:#{child.id}" } ])
      expect(response.body).not_to include(child.cns)
    end

    it "dose registrada: o item traz applied { id, applied_at, transcription } e a lista de <immunization>" do
      child = vaccine_patient!(birth_date: today - 90)
      dose = create_immunization!(room, patient: child, vaccinator_user: vaccinator, applied_at: 20.days.ago)
      card(patient_id: child.id)
      applied = item("42", "1").fetch("applied")
      expect(item("42", "1")["status"]).to eq("complete")
      expect(applied.keys).to eq(%w[id applied_at transcription])
      expect(applied).to include("id" => dose.id, "transcription" => false)
      expect(Time.iso8601(applied["applied_at"]).to_i).to eq(dose.applied_at.to_i)
      immunization = json_body["immunizations"].sole
      expect(immunization).to include("id" => dose.id, "immunobiological" => { "code" => "42", "name" => "Vacina penta (DTP/HB/Hib)" },
                                      "transcription" => false, "status" => "active", "cancel_reason" => nil, "replaces_id" => nil,
                                      "replaced_by_id" => nil, "campaign_id" => nil, "strategy" => "1", "care_group" => "121")
      expect(immunization["room"]).to eq("id" => room.id, "name" => room.name, "health_unit" => { "id" => room.health_unit.id, "name" => room.health_unit.name })
      expect(immunization["lot"]).to include("id" => dose.stock_lot_id, "number" => dose.stock_lot.lot_number)
      expect(immunization["by"]).to eq("name" => vaccinator.professional.professional_name, "cbo" => "322205")
      expect(immunization["rnds"]).to eq("status" => "not_sent", "sent_at" => nil, "accepted_at" => nil, "block_reason" => nil, "error" => nil)
    end

    it "nascido depois do go-live: a caderneta já vem conferida (born_after_go_live)" do
      go_live!(today - 200)
      baby = vaccine_patient!(birth_date: today - 100)
      card(patient_id: baby.id)
      expect(json_body["checked"]).to include("mode" => "born_after_go_live", "by_name" => nil)
      expect(VaccinationStatus.where(patient_id: baby.id)).to exist
    end

    it "patient_id inexistente ou malformado → 404; os dois ou nenhum → 422; nenhuma trilha" do
      card(patient_id: SecureRandom.uuid)
      expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
      card(patient_id: "x")
      expect(response).to have_http_status(:not_found)
      card({})
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "patient_id") ])
      card(patient_id: SecureRandom.uuid, new_patient: { full_name: "Bebê Souza" })
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "patient_id") ])
      expect(trail).to be_empty
    end

    it "fora da equipe da sala → 403; sala inexistente → 404; interruptor desligado → 403 feature_disabled" do
      child = vaccine_patient!(birth_date: today - 90)
      other_room = vaccine_room!
      sign_in_as(room_member!(other_room))
      card(patient_id: child.id)
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
      sign_in_as(staff_with("ninguem-#{SecureRandom.hex(3)}@cidade.gov.br", "health_professional"))
      card(patient_id: child.id)
      expect(response).to have_http_status(:forbidden)
      sign_in_as(vaccinator)
      post_json("/vaccination/rooms/#{SecureRandom.uuid}/card", { patient_id: child.id })
      expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
      Platform::Features.set!(city: city, key: "vaccination", enabled: false, maintainer: ledi_maintainer!)
      card(patient_id: child.id)
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "vaccination" } ])
      expect(trail).to be_empty
    end

    describe "new_patient (recém-nascido sem cadastro; a forma do 24a)" do
      def newborn(**over)
        { full_name: "Heitor Almeida Souza", birth_date: (today - 3).iso8601, sex: "male", mother_name: "Carla Almeida Souza",
          no_cpf_reason: "3" }.merge(over)
      end

      it "cria o paciente (patient.created), devolve a caderneta e grava a trilha; nascido depois do go-live já vem conferido" do
        go_live!(today - 365)
        expect { card(new_patient: newborn) }.to change(Patient, :count).by(1)
        expect(response).to have_http_status(:ok)
        created = Patient.find(json_body["patient"]["id"])
        expect(json_body["patient"]).to include("display_name" => "Heitor Almeida Souza", "has_cpf" => false)
        expect(json_body["checked"]).to include("mode" => "born_after_go_live")
        expect(DomainEvent.where(name: "patient.created").last.payload).to include("patient_id" => created.id)
        expect(trail.pluck("patient_id")).to eq([ created.id ])
      end

      it "mesmo nome e nascimento de paciente gravado → 409 duplicate_suspected, nada criado; com duplicates_reviewed: true, cria" do
        card(new_patient: newborn)
        expect { card(new_patient: newborn) }.not_to change(Patient, :count)
        expect([ response.status, json_body ]).to eq([ 409, { "error" => "duplicate_suspected" } ])
        expect { card(new_patient: newborn, duplicates_reviewed: true) }.to change(Patient, :count).by(1)
        card(new_patient: newborn, duplicates_reviewed: "sim")
        expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "duplicates_reviewed") ])
      end

      it "recusas de forma com o path new_patient.<campo>; nada criado" do
        expect { card(new_patient: newborn(full_name: "X")) }.not_to change(Patient, :count)
        expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_patient", "new_patient.full_name") ])
        card(new_patient: newborn(no_cpf_reason: nil))
        expect([ response.status, json_body ]).to eq([ 422, refusal("cpf_or_reason_required", "new_patient.no_cpf_reason") ])
        card(new_patient: "Heitor")
        expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "new_patient") ])
        expect(trail).to be_empty
      end
    end
  end

  describe "POST /vaccination/rooms/:room_id/checks" do
    it "confirmed_complete: grava a conferência, recalcula a situação, devolve a caderneta com checked.mode; evento só com ids; uma trilha" do
      child = vaccine_patient!(birth_date: today - 365)
      check(patient_id: child.id, mode: "confirmed_complete")
      expect(response).to have_http_status(:ok)
      record = VaccinationRecordCheck.find_by!(patient_id: child.id)
      expect(record).to have_attributes(mode: "confirmed_complete", checked_by_user_id: vaccinator.id, vaccine_room_id: room.id)
      expect(json_body["checked"].except("at")).to eq("mode" => "confirmed_complete", "by_name" => vaccinator.professional.professional_name)
      expect(Time.iso8601(json_body["checked"]["at"]).to_i).to eq(record.checked_at.to_i)
      expect(json_body["items"].map { |i| i["status"] }).to include("overdue")
      expect(VaccinationStatus.where(patient_id: child.id).pluck(:checked).uniq).to eq([ true ])
      expect(DomainEvent.where(name: "vaccination.record_checked").sole.payload)
        .to eq("vaccination_record_check_id" => record.id, "vaccine_room_id" => room.id, "user_id" => vaccinator.id)
      expect(trail.size).to eq(1)
    end

    it "modo que não é confirmed_complete → 422 path mode; inexistente → 404; fora da equipe → 403; nada gravado" do
      child = vaccine_patient!(birth_date: today - 365)
      %w[transcribed born_after_go_live x].each do |mode|
        check(patient_id: child.id, mode: mode)
        expect([ mode, response.status, json_body ]).to eq([ mode, 422, refusal("invalid_request", "mode") ])
      end
      check(patient_id: SecureRandom.uuid, mode: "confirmed_complete")
      expect(response).to have_http_status(:not_found)
      sign_in_as(room_member!(vaccine_room!))
      check(patient_id: child.id, mode: "confirmed_complete")
      expect(response).to have_http_status(:forbidden)
      expect(VaccinationRecordCheck.where(patient_id: child.id)).to be_empty
      expect(trail).to be_empty
    end
  end

  describe "POST /vaccination/rooms/:room_id/person_lookup (a forma do 27a)" do
    def person_shape(person) = { "patient_id" => person.id, "display_name" => person.display_name, "has_cpf" => person.cpf.present?, "cns_masked" => person.cns_masked }

    it "pelo CPF e pelo CNS: id, nome, has_cpf e cns_masked; nunca o CPF nem o CNS inteiros; trilha por pessoa" do
      with_cpf = vaccine_patient!(birth_date: today - 400)
      no_cpf = vaccine_patient!(birth_date: today - 30, cpf: false)
      lookup(cpf: with_cpf.cpf.sub(/(\d{3})(\d{3})(\d{3})(\d{2})/, '\\1.\\2.\\3-\\4'))
      expect([ response.status, json_body ]).to eq([ 200, person_shape(with_cpf) ])
      expect(response.body).not_to include(with_cpf.cpf)
      lookup(cns: no_cpf.cns)
      expect([ response.status, json_body ]).to eq([ 200, person_shape(no_cpf) ])
      expect(response.body).not_to include(no_cpf.cns)
      expect(trail.pluck("patient_id")).to eq([ with_cpf.id, no_cpf.id ])
    end

    it "par validado sem paciente cria o paciente; só declarado → 409; ninguém → 404; inválidos → 422; query → 422; recusa sem trilha" do
      citizen = verified_citizen!(31)
      expect { lookup(cpf: citizen.cpf) }.to change(Patient, :count).by(1)
      created = Patient.find_by!(cpf: citizen.cpf)
      expect(json_body["patient_id"]).to eq(created.id)
      expect(trail.pluck("patient_id")).to eq([ created.id ])
      lookup(cpf: screening_citizen!(32).cpf)
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "citizen_not_verified" } ])
      lookup(cns: valid_cns(3))
      expect([ response.status, json_body ]).to eq([ 404, { "error" => "person_not_found" } ])
      lookup(cpf: "123")
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_cpf", "cpf") ])
      lookup(cns: "123")
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_cns", "cns") ])
      lookup(cpf: valid_cpf(1), cns: valid_cns(1))
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "cns") ])
      lookup({})
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "cpf") ])
      lookup({}, query: "?cpf=#{citizen.cpf}")
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "cpf") ])
      expect(trail.size).to eq(1) # só a do paciente criado
    end

    it "fora da equipe da sala → 403" do
      sign_in_as(room_member!(vaccine_room!))
      lookup(cpf: vaccine_patient!(birth_date: today - 400).cpf)
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
    end

    it "o log da requisição não leva CPF nem CNS" do
      person = vaccine_patient!(birth_date: today - 400)
      log = capture_log { lookup(cpf: person.cpf) } + capture_log { lookup(cns: person.cns) }
      [ person.cpf, person.cns, person.full_name ].each { |secret| expect(log).not_to include(secret) }
    end
  end

  # §15 V21: duplicados na rota da sala, no padrão do /pharmacy/patients/duplicates.
  describe "POST /vaccination/rooms/:room_id/patients/duplicates" do
    def duplicates(body = {}, query: "", **fields) = post_json("/vaccination/rooms/#{room.id}/patients/duplicates", body.merge(fields), query: query)

    let!(:twin) do
      Patient.create!(cpf: valid_cpf(registry_seq!), full_name: "José Souza Lima", birth_date: "2026-10-01", sex: "male", mother_name: "Rita Souza Lima")
    end

    it "membro da sala recebe os candidatos na forma do 25, com trilha por candidato; sem territory_registry" do
      expect(Platform::Features.enabled?(city, "territory_registry")).to be(false)
      duplicates(full_name: "Jose Souza-Lima", birth_date: "2026-10-01")
      expect(response).to have_http_status(:ok)
      expect(json_body).to eq("candidates" => [ { "patient_id" => twin.id, "display_name" => "José Souza Lima", "birth_date" => "2026-10-01", "has_cpf" => true } ])
      expect(trail.pluck("patient_id")).to eq([ twin.id ])
      expect(response.body).not_to include(twin.cpf, "Rita")
      duplicates(full_name: "José Souza Lima", birth_date: "2026-10-01", mother_name: "Ana Outra")
      expect(json_body["candidates"]).to eq([])
    end

    it "recusas de forma e query → 422; fora da equipe → 403; nenhuma trilha" do
      duplicates(full_name: "José Souza Lima", birth_date: "01/10/2026")
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "birth_date") ])
      duplicates({ birth_date: "2026-10-01" }, query: "?full_name=Jose")
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "full_name") ])
      sign_in_as(room_member!(vaccine_room!))
      duplicates(full_name: "José Souza Lima", birth_date: "2026-10-01")
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
      expect(trail).to be_empty
    end
  end
end