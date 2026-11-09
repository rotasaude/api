require "rails_helper"

# Módulo 32a (ADR 0050; plano, Task 4 e Desvio 8; contrato §13 e §14 Q1, Q3,
# Q8, Q16, Q18): o esquema da urgência e da sala de espera, por gravações
# diretas (os caminhos reais são os comandos das Tasks 6–12). As recusas vêm
# do banco (CHECKs, índices e os triggers de db/city_triggers.sql), não do
# modelo.
RSpec.describe "Esquema da urgência e da sala de espera", type: :model do
  let!(:city) { clinical_city! }
  let(:upa) { create_unit("UPA Esquema", kind: "upa") }
  let(:nurse) { screener!(upa, cbo: "223505") }
  let!(:link) { nurse.professional.links.active.find_by!(health_unit: upa) }
  let(:attendance) { walk_in!(upa) }
  let!(:encounter) { UrgencyEncounter.create!(attendance: attendance) }

  # Savepoint: cada recusa aborta a transação; o savepoint deixa a próxima viva.
  def attempt(&) = ApplicationRecord.transaction(requires_new: true, &)

  def walk_in!(unit)
    patient = Patient.create!(no_cpf_reason: "unidentified", unidentified: true, unidentified_description: "Homem, 40 anos, rodoviária")
    Attendance.create!(origin_kind: "walk_in", patient: patient, health_unit: unit, checked_in_by_user: reception!,
                       checked_in_at: Time.current, check_in_method: "urgency_reception")
  end

  def classification!(enc, position: 1, color: "red", suggested_color: "red", suggested_rule_id: "spo2-critica", justification: nil, **over)
    UrgencyClassification.create!(urgency_encounter: enc, position: position, color: color, suggested_color: suggested_color,
                                  suggested_rule_id: suggested_color && suggested_rule_id, criterion: suggested_color && "SpO2 abaixo de 90%",
                                  complaint: "Falta de ar intensa desde a madrugada", vital_signs: { "spo2" => 85 }, pain_scale: 2,
                                  justification: justification, max_wait_minutes: 0, classified_by_user: nurse,
                                  professional_link: link, cbo_code: link.cbo_code, **over)
  end

  def classify_encounter!(enc, classification)
    enc.update!(state: "classified", current_classification: classification, first_classified_at: Time.current)
  end

  describe "urgency_encounters" do
    it "nasce aguardando a classificação, um por atendimento" do
      expect(encounter.reload).to have_attributes(state: "waiting_classification", current_classification_id: nil, first_classified_at: nil)
      expect(attendance.reload.urgency_encounter).to eq(encounter)
      expect { attempt { UrgencyEncounter.create!(attendance: attendance) } }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "o estado só anda para frente; fechado, nunca muda; nunca some" do
      first = classification!(encounter)
      classify_encounter!(encounter, first)
      expect(encounter.reload).to have_attributes(state: "classified", color: "red")
      expect(encounter.patient).to eq(attendance.patient)

      expect { attempt { encounter.update_columns(state: "waiting_classification", current_classification_id: nil, first_classified_at: nil) } }
        .to raise_error(ActiveRecord::StatementInvalid, /state only moves forward/)
      expect { attempt { encounter.update_column(:first_classified_at, 1.hour.ago) } }
        .to raise_error(ActiveRecord::StatementInvalid, /first classification is recorded once/)

      # Reclassificar troca a classificação vigente sem mudar o estado.
      second = classification!(encounter, position: 2, color: "orange", suggested_color: "orange")
      encounter.reload.update!(current_classification: second)
      expect(encounter.reload.color).to eq("orange")
      expect(encounter.classifications.map(&:position)).to eq([ 1, 2 ])

      encounter.update!(state: "in_care")
      expect { attempt { encounter.update_column(:state, "classified") } }.to raise_error(ActiveRecord::StatementInvalid, /state only moves forward/)
      encounter.reload.update!(state: "closed")
      expect(encounter.reload).to be_closed
      expect { attempt { encounter.update_column(:current_classification_id, first.id) } }
        .to raise_error(ActiveRecord::StatementInvalid, /a closed encounter never changes/)
      expect { attempt { encounter.delete } }.to raise_error(ActiveRecord::StatementInvalid, /DELETE refused/)
    end

    # Task 9 (R4): o provisório com que o encontro nasceu, gravado na chegada,
    # é o paciente provisório do próprio atendimento e nunca muda (nem na fusão).
    it "provisional_patient_id: só o provisório do atendimento, na criação, e nunca muda" do
      other = walk_in!(upa)
      identified = Patient.create!(cpf: "52998224725", full_name: "Carlos Eduardo Pinto", birth_date: "1980-02-01", sex: "male")
      expect { attempt { UrgencyEncounter.create!(attendance: other, provisional_patient: attendance.patient) } }
        .to raise_error(ActiveRecord::StatementInvalid, /the attendance's unidentified patient/)
      with_provisional = UrgencyEncounter.create!(attendance: other, provisional_patient: other.patient)
      expect(with_provisional.reload.provisional_patient).to eq(other.patient)
      expect { attempt { with_provisional.update_column(:provisional_patient_id, identified.id) } }
        .to raise_error(ActiveRecord::StatementInvalid, /the provisional patient never changes/)
      expect { attempt { encounter.update_column(:provisional_patient_id, attendance.patient_id) } }
        .to raise_error(ActiveRecord::StatementInvalid, /the provisional patient never changes/)
    end

    it "da espera, só para classificado ou fechado (evasão antes da classificação)" do
      expect { attempt { encounter.update_column(:state, "in_care") } }.to raise_error(ActiveRecord::StatementInvalid, /state only moves forward/)
      encounter.reload.update!(state: "closed")
      expect(encounter.reload).to have_attributes(state: "closed", current_classification_id: nil, first_classified_at: nil)
    end

    it "estado, classificação vigente e 1ª classificação andam juntos (CHECK)" do
      first = classification!(encounter)
      expect { attempt { encounter.update_columns(state: "classified") } }
        .to raise_error(ActiveRecord::StatementInvalid, /ck_urgency_encounters_classification/)
      expect { attempt { encounter.update_columns(state: "classified", current_classification_id: first.id) } }
        .to raise_error(ActiveRecord::StatementInvalid, /ck_urgency_encounters_classification/)
    end

    it "a classificação vigente é sempre do mesmo encontro" do
      other = UrgencyEncounter.create!(attendance: walk_in!(upa))
      foreign = classification!(other)
      expect { attempt { classify_encounter!(encounter, foreign) } }
        .to raise_error(ActiveRecord::StatementInvalid, /classification of another encounter/)
    end

    it "atendimento, criação e consulta não mudam depois de gravados" do
      other = walk_in!(upa)
      expect { attempt { encounter.update_column(:attendance_id, other.id) } }
        .to raise_error(ActiveRecord::StatementInvalid, /attendance and creation never change/)
      expect { attempt { encounter.update_column(:created_at, 1.day.ago) } }
        .to raise_error(ActiveRecord::StatementInvalid, /attendance and creation never change/)
    end
  end

  describe "urgency_classifications" do
    it "cor diferente da sugerida, ou sem sugestão, exige justificativa" do
      expect { attempt { classification!(encounter, color: "yellow", suggested_color: "red") } }
        .to raise_error(ActiveRecord::StatementInvalid, /ck_urgency_classifications_justification/)
      expect { attempt { classification!(encounter, color: "yellow", suggested_color: nil) } }
        .to raise_error(ActiveRecord::StatementInvalid, /ck_urgency_classifications_justification/)
      expect(classification!(encounter, color: "yellow", suggested_color: nil, justification: "Avaliação clínica de enfermagem"))
        .to be_persisted
      expect(classification!(encounter, position: 2, color: "red", suggested_color: "red")).to be_persisted
    end

    it "sugestão com a regra, ou nenhuma das duas; dor de 0 a 10; posição única por encontro" do
      expect { attempt { classification!(encounter, suggested_rule_id: nil) } }.to raise_error(ActiveRecord::StatementInvalid, /ck_urgency_classifications_suggestion/)
      expect { attempt { classification!(encounter, pain_scale: 11) } }.to raise_error(ActiveRecord::StatementInvalid, /ck_urgency_classifications_domains/)
      expect { attempt { classification!(encounter, pain_scale: nil) } }.to raise_error(ActiveRecord::NotNullViolation)
      expect { attempt { classification!(encounter, max_wait_minutes: 1441) } }
        .to raise_error(ActiveRecord::StatementInvalid, /ck_urgency_classifications_domains/)
      expect { attempt { classification!(encounter, color: "purple", suggested_color: "purple") } }
        .to raise_error(ActiveRecord::StatementInvalid, /ck_urgency_classifications_domains/)
      classification!(encounter)
      expect { attempt { classification!(encounter) } }.to raise_error(ActiveRecord::RecordNotUnique, /idx_urgency_classifications_position/)
    end

    it "só acréscimo: não muda nem some; a re-cifra regrava só as cifradas" do
      classification = classification!(encounter)
      expect { attempt { classification.update_column(:color, "blue") } }.to raise_error(ActiveRecord::StatementInvalid, /append-only: UPDATE refused/)
      expect { attempt { classification.delete } }.to raise_error(ActiveRecord::StatementInvalid, /append-only: DELETE refused/)
      CityEncryption.allowing_reencryption { classification.update_column(:complaint, "Falta de ar intensa desde a madrugada") }
      expect(classification.reload.complaint).to eq("Falta de ar intensa desde a madrugada")
    end

    it "queixa, sinais, critério e justificativa cifrados; inspect e as_json só com o id" do
      classification = classification!(encounter, color: "orange", suggested_color: "red", justification: "Dor torácica típica, ECG alterado")
      raw = ApplicationRecord.connection.select_one(
        "SELECT complaint, vital_signs, criterion, justification FROM urgency_classifications WHERE id = #{ApplicationRecord.connection.quote(classification.id)}"
      )
      expect(raw.values.join).not_to include("Falta de ar", "spo2", "SpO2", "ECG")
      expect(classification.reload.vital_signs).to eq("spo2" => 85)
      expect(classification.as_json).to eq("id" => classification.id)
      expect(classification.inspect).not_to include("Falta de ar")
      expect(classification.to_s).to eq(classification.inspect)
      expect(encounter.as_json).to eq("id" => encounter.id)
    end
  end

  describe "urgency_outcomes" do
    def outcome!(enc, kind: "discharged", **over)
      UrgencyOutcome.create!(urgency_encounter: enc, kind: kind, recorded_by_user: nurse, recorded_at: Time.current, **over)
    end

    it "um por encontro, só acréscimo, cifrado e sem dado no inspect" do
      outcome = outcome!(encounter, kind: "transferred", destination: "Hospital Evangélico", vacancy_request: "Central de leitos 4471")
      expect { attempt { outcome!(encounter) } }.to raise_error(ActiveRecord::RecordNotUnique)
      expect { attempt { outcome.update_column(:kind, "death") } }.to raise_error(ActiveRecord::StatementInvalid, /append-only: UPDATE refused/)
      expect { attempt { outcome.delete } }.to raise_error(ActiveRecord::StatementInvalid, /append-only: DELETE refused/)
      raw = ApplicationRecord.connection.select_value("SELECT destination FROM urgency_outcomes WHERE id = #{ApplicationRecord.connection.quote(outcome.id)}")
      expect(raw).not_to include("Evangélico")
      expect(outcome.as_json).to eq("id" => outcome.id)
      expect(outcome.inspect).not_to include("Evangélico")
      expect(encounter.reload.outcome).to eq(outcome)
    end

    it "destino só e sempre na transferência; retorno com motivo só na alta para a UBS" do
      expect { attempt { outcome!(encounter, kind: "transferred") } }.to raise_error(ActiveRecord::StatementInvalid, /ck_urgency_outcomes_destination/)
      expect { attempt { outcome!(encounter, destination: "Hospital") } }.to raise_error(ActiveRecord::StatementInvalid, /ck_urgency_outcomes_destination/)
      expect { attempt { outcome!(encounter, kind: "discharged_to_primary_care") } }
        .to raise_error(ActiveRecord::StatementInvalid, /ck_urgency_outcomes_return/)
      expect { attempt { outcome!(encounter, kind: "discharged_to_primary_care", return_days: 5) } }
        .to raise_error(ActiveRecord::StatementInvalid, /ck_urgency_outcomes_return/)
      expect { attempt { outcome!(encounter, kind: "discharged_to_primary_care", return_days: 91, return_reason: "Curativo") } }
        .to raise_error(ActiveRecord::StatementInvalid, /ck_urgency_outcomes_domains/)
      expect { attempt { outcome!(encounter, vacancy_request: "Central 1") } }
        .to raise_error(ActiveRecord::StatementInvalid, /ck_urgency_outcomes_vacancy_request/)
      expect { attempt { outcome!(encounter, counter_referral_health_unit: create_unit("UBS Retorno")) } }
        .to raise_error(ActiveRecord::StatementInvalid, /ck_urgency_outcomes_counter_referral/)
      expect { attempt { outcome!(encounter, kind: "escaped") } }.to raise_error(ActiveRecord::StatementInvalid, /ck_urgency_outcomes_domains/)
      ubs = create_unit("UBS Retorno 2")
      outcome = outcome!(encounter, kind: "discharged_to_primary_care", return_days: 5, return_reason: "Curativo da ferida",
                                    counter_referral_health_unit: ubs)
      expect(outcome.reload).to have_attributes(return_days: 5, return_reason: "Curativo da ferida", counter_referral_health_unit: ubs)
    end
  end

  describe "sala de espera" do
    let(:admin) { staff_with("admin-tv-#{SecureRandom.hex(3)}@cidade.gov.br", "municipal_admin") }

    it "chamadas só de acréscimo" do
      call = AttendanceCall.create!(attendance: attendance, ticket: "U-001", kind: "classification", called_at: Time.current,
                                    called_by_user: nurse)
      expect { attempt { call.update_column(:kind, "care") } }.to raise_error(ActiveRecord::StatementInvalid, /append-only: UPDATE refused/)
      expect { attempt { call.delete } }.to raise_error(ActiveRecord::StatementInvalid, /append-only: DELETE refused/)
      expect { attempt { AttendanceCall.create!(attendance: attendance, kind: "triage", called_at: Time.current, called_by_user: nurse) } }
        .to raise_error(ActiveRecord::StatementInvalid, /ck_attendance_calls_domains/)
    end

    it "local com nome único por unidade sem diferença de caixa; nunca some" do
      location = CallLocation.create!(health_unit: upa, name: "consultório 1", updated_by_user: admin)
      expect { attempt { CallLocation.create!(health_unit: upa, name: "Consultório 1", updated_by_user: admin) } }
        .to raise_error(ActiveRecord::RecordNotUnique, /idx_call_locations_name/)
      expect(CallLocation.create!(health_unit: create_unit("UPA Outra", kind: "upa"), name: "Consultório 1", updated_by_user: admin)).to be_persisted
      location.update!(active: false)
      expect(upa.call_locations.active).to be_empty
      expect { attempt { location.delete } }.to raise_error(ActiveRecord::StatementInvalid, /DELETE refused/)
    end

    it "TV: código com validade, token só como SHA-256, pareada e ativa; nunca some" do
      display = WaitingRoomDisplay.create!(health_unit: upa, name: "TV da recepção", created_by_user: admin)
      expect(display.reload).to have_attributes(active: true, show_wait_times: true, last_seen_at: nil, token_digest: nil)
      expect { attempt { display.update_column(:pairing_code_digest, WaitingRoomDisplay.digest("123456")) } }
        .to raise_error(ActiveRecord::StatementInvalid, /ck_waiting_room_displays_pairing/)
      expect(WaitingRoomDisplay.paired_active).to be_empty

      token = SecureRandom.urlsafe_base64(48)
      display.update!(token_digest: WaitingRoomDisplay.digest(token), paired_at: Time.current)
      expect(WaitingRoomDisplay.by_token(token)).to eq(display)
      expect(WaitingRoomDisplay.by_token("curto")).to be_nil
      expect(WaitingRoomDisplay.paired_active).to eq([ display ])
      expect(display.inspect).not_to include(display.token_digest)
      twin = WaitingRoomDisplay.create!(health_unit: upa, name: "TV 2", created_by_user: admin)
      expect { attempt { twin.update_column(:token_digest, display.token_digest) } }.to raise_error(ActiveRecord::RecordNotUnique)

      display.update!(revoked_at: Time.current)
      expect(display).to be_revoked
      expect(WaitingRoomDisplay.paired_active).to be_empty
      expect(upa.waiting_room_displays).to contain_exactly(display, twin)
      expect { attempt { display.delete } }.to raise_error(ActiveRecord::StatementInvalid, /DELETE refused/)
    end
  end

  it "TRUNCATE recusado nas seis tabelas" do
    %w[urgency_encounters urgency_classifications urgency_outcomes call_locations attendance_calls waiting_room_displays].each do |table|
      expect { attempt { ApplicationRecord.connection.execute("TRUNCATE #{table} CASCADE") } }
        .to raise_error(ActiveRecord::StatementInvalid, /append-only: TRUNCATE refused/), table
    end
  end

  # Contrato §14 Q1/Q16: um protocolo de urgência ativo por cidade, pelo kind
  # (sem nome reservado). insert_all: a forma do protocolo é da Task 5.
  it "um só protocolo de urgência ativo por cidade, pelo kind, de qualquer nome" do
    row = lambda do |name, kind, status: "active"|
      { name: name, version: 1, status: status, definition: { "name" => name, "version" => 1, "kind" => kind },
        created_at: Time.current, updated_at: Time.current }
    end
    ProtocolDefinition.insert_all!([ row.call("urgencia-a", "urgency_classification"), row.call("acolhimento", "screening"),
                                     row.call("urgencia-b", "urgency_classification", status: "published") ])
    expect { attempt { ProtocolDefinition.insert_all!([ row.call("urgencia-c", "urgency_classification") ]) } }
      .to raise_error(ActiveRecord::RecordNotUnique, /idx_protocol_definitions_one_active_urgency/)
    expect { attempt { ProtocolDefinition.where(name: "urgencia-b").update_all(status: "active") } }
      .to raise_error(ActiveRecord::RecordNotUnique, /idx_protocol_definitions_one_active_urgency/)
    ProtocolDefinition.where(name: "urgencia-a").update_all(status: "published")
    ProtocolDefinition.where(name: "urgencia-b").update_all(status: "active")
    expect(ProtocolDefinition.active.pluck(:name)).to contain_exactly("acolhimento", "urgencia-b")
  end
end
