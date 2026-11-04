require "rails_helper"

# Módulo 31, Task 16 (ADR 0049; ADR 0026; contrato §14, §15 P17 e P45): o que é
# do CAPS é registro de saúde e retém o paciente — matrícula em qualquer
# situação, participação em ação (cancelada inclusive; o family_name fica com a
# ação), permanência e caso de matriciamento. A linha BPA-I do CAPS já retém
# pelo faturamento (P45) e o documento do CAPS (citizen_id nulo, Task 13) vem
# sempre de uma ação. Sem nada disso, a confirmação anonimiza o encaminhamento
# e o acolhimento (cifradas → NULL e anonymized_at, uma vez, pelo trigger).
RSpec.describe "Exclusão LGPD com registro do CAPS (ADR 0049)" do
  before do
    # O caminho real do encaminhamento tem atendimento no par (contexto da UBS):
    # aqui ele é desligado para isolar a regra nova.
    allow(Citizens::RequestErasure).to receive_messages(attended?: false, documented?: false)
  end

  let!(:city) { psychosocial_city! }
  let(:caps) { caps! }
  let(:staff) { caps_staff!(caps) }
  let(:patient) { caps_patient! }
  let(:citizen) { Patients::Pairs.of(patient).sole }
  let(:reason) { "Ideação persistente, sem resposta a duas tentativas terapêuticas na UBS" }

  def request_for(citizen) = Citizens::RequestErasure.call(cpf: citizen.cpf, document_checked: true, by: verifier!)
  def recorded? = Citizens::RequestErasure.psychosocial_recorded?([ patient.id ])

  def referral!(of: patient)
    ubs = create_unit("UBS #{SecureRandom.hex(3)}")
    PsychosocialReferral.create!(patient: of, health_unit: caps, from_health_unit: ubs, referred_by_user: ubs_doctor!(ubs),
                                 reason: reason, priority: "routine")
  end

  # Acolhimento pela via real (Psychosocial::RecordReception): é também uma ação.
  def reception!(outcome: "no_follow_up", referral: nil)
    attrs = { "patient_id" => patient.id, "at" => 1.minute.ago.iso8601, "sigtap_code" => "0301080232",
              "notes" => "Chegou sozinho; não quis seguir", "outcome" => outcome }
    attrs["referral_id"] = referral.id if referral
    result = Psychosocial::RecordReception.call(attrs: attrs, unit: caps, by: staff)
    raise "reception! recusado: #{result.reason}" if result.failure?

    result.payload.fetch(:reception)
  end

  def refused(pattern = nil, &block)
    expect { ApplicationRecord.transaction(requires_new: true, &block) }.to raise_error(ActiveRecord::StatementInvalid, pattern)
  end

  describe "retenção" do
    it "matrícula encerrada retém: o pedido nasce retido" do
      enrollment = enrollment!(caps, patient: patient)
      enrollment.update!(closed_on: Date.current, destination: "01", closed_by_user: staff)
      expect(recorded?).to be(true)
      expect(request_for(citizen).payload[:request].status).to eq("retained")
    end

    it "acolhimento no_follow_up com a ação cancelada: retido, e nada é anonimizado" do
      reception = reception!
      action = PsychosocialActionParticipant.find_by!(patient_id: patient.id).psychosocial_action
      expect(Psychosocial::CancelAction.call(action: action, reason: "Registrada no usuário errado", by: staff).failure?).to be(false)
      expect(PsychosocialEnrollment.where(patient_id: patient.id)).not_to exist

      expect(recorded?).to be(true)
      request = request_for(citizen).payload[:request]
      expect(request.status).to eq("retained")
      expect(reception.reload).to have_attributes(anonymized_at: nil, notes: "Chegou sozinho; não quis seguir")
    end

    it "participação em ação retém; o familiar sem cadastro fica com a ação (P17)" do
      enrollment = enrollment!(caps, patient: patient)
      action = record_action!(caps, staff, sigtap_code: "0301080224",
                                           participants: [ { enrollment_id: enrollment.id }, { family_name: "Maria Irmã Pereira" } ])
      request = request_for(citizen).payload[:request]
      expect(request.status).to eq("retained")
      family = action.psychosocial_action_participants.find_by!(patient_id: nil)
      expect(family.family_name).to eq("Maria Irmã Pereira")
    end

    it "só a participação em ação (sem matrícula) já retém" do
      record_action!(caps, staff, sigtap_code: "0301080232", participants: [ { patient_id: patient.id } ])
      expect(PsychosocialEnrollment.where(patient_id: patient.id)).not_to exist
      expect(recorded?).to be(true)
    end

    it "caso de matriciamento retém, sem matrícula nem ação do paciente" do
      ubs = create_unit("UBS Boa Vista")
      team = HealthTeam.create!(health_unit: ubs, ine: "0000123456", kind: "70", name: "eSF Boa Vista")
      matrix_case!(caps, team, patient, "Caso discutido antes de qualquer acolhimento")
      expect(PsychosocialActionParticipant.where(patient_id: patient.id)).not_to exist
      expect(recorded?).to be(true)
    end

    # A permanência sempre tem matrícula (que já retém): a linha com a
    # matrícula de outro paciente isola a regra da permanência.
    it "permanência retém" do
      unit = caps!(modality: "caps_ad_iii")
      other = enrollment!(unit)
      expect(recorded?).to be(false)
      PsychosocialNightStay.create!(psychosocial_bed: bed!(unit), health_unit: unit, psychosocial_enrollment: other, patient_id: patient.id,
                                    started_at: 2.days.ago.change(hour: 19), expected_end_at: 1.day.ago.change(hour: 8),
                                    ended_at: 1.day.ago.change(hour: 8), end_reason: "Alta do acolhimento",
                                    started_by_user: other.reference_user, closed_by_user: other.reference_user)
      expect(recorded?).to be(true)
    end

    it "documento do CAPS (citizen_id nulo) não passa pelo documented?, mas o paciente fica retido" do
      allow(Citizens::RequestErasure).to receive(:documented?).and_call_original
      action = record_action!(caps, staff, sigtap_code: "0301080232", participants: [ { patient_id: patient.id } ])
      document = caps_document!(action)
      expect(document.citizen_id).to be_nil
      expect(Citizens::RequestErasure.documented?(Citizen.where(id: citizen.id))).to be(false)
      expect(request_for(citizen).payload[:request].status).to eq("retained")
    end
  end

  # P45: a linha BPA-I do CAPS (performed_procedures, source psychosocial) já
  # retém pelo caminho do faturamento, sem depender da regra do CAPS.
  describe "linha BPA-I do CAPS (P45)" do
    let!(:city) { psychosocial_city!(billing: true) }

    it "retém o paciente pelo faturamento" do
      action = record_action!(caps, staff, sigtap_code: "0301080232", participants: [ { patient_id: patient.id } ])
      line = Billing::FromPsychosocial.call(action)
      expect(line).to have_attributes(source: "psychosocial", instrument: "bpa_i", patient_id: patient.id)

      allow(Citizens::RequestErasure).to receive(:psychosocial_recorded?).and_return(false)
      expect(Citizens::RequestErasure.examined_patients?([ patient.id ])).to be(true)
      expect(request_for(citizen).payload[:request].status).to eq("retained")
    end
  end

  describe "sem registro do CAPS: confirmação" do
    it "quem só foi encaminhado: confirmado; o motivo vira NULL com anonymized_at; o evento leva só o id" do
      referral = referral!
      other = referral!(of: caps_patient!)
      expect(recorded?).to be(false)

      request = request_for(citizen).payload[:request]
      expect(request.status).to eq("pending")
      result = Citizens::Erase.call(request: request, by: care_admin!)
      expect(result.payload[:request].status).to eq("confirmed")

      referral.reload
      expect(referral.anonymized_at).to be_present
      expect(referral.read_attribute_before_type_cast(:reason)).to be_nil
      expect(referral).to have_attributes(status: "pending", patient_id: patient.id)
      expect(other.reload).to have_attributes(anonymized_at: nil, reason: reason)
      DomainEvent.where(name: %w[citizen.erasure_requested citizen.erased]).each do |event|
        expect(event.payload.keys).to eq([ "request_id" ])
      end
    end

    it "acolhimento sem ação (defensivo: a via real sempre grava a ação) é anonimizado junto" do
      reception = PsychosocialReception.create!(health_unit: caps, patient: patient, at: 1.hour.ago, sigtap_code: "0301080232",
                                                notes: "Não quis seguir", outcome: "no_follow_up", recorded_by_user: staff)
      expect(recorded?).to be(false)

      Citizens::Erase.call(request: request_for(citizen).payload[:request], by: care_admin!)
      reception.reload
      expect(reception.anonymized_at).to be_present
      expect(reception.read_attribute_before_type_cast(:notes)).to be_nil
    end

    it "encaminhamento anonimizado não é mais recebido (409 referral_not_pending)" do
      referral = referral!
      Citizens::Erase.call(request: request_for(citizen).payload[:request], by: care_admin!)

      result = Psychosocial::RecordReception.call(
        attrs: { "patient_id" => patient.id, "referral_id" => referral.id, "at" => 1.minute.ago.iso8601,
                 "sigtap_code" => "0301080232", "outcome" => "no_follow_up" },
        unit: caps, by: staff
      )
      expect(result.reason).to eq(:referral_not_pending)
      expect(PsychosocialReception.where(patient_id: patient.id)).not_to exist
      expect(referral.reload.status).to eq("pending")
    end

    it "Psychosocial::Anonymize.patients! é idempotente (filtro anonymized_at IS NULL)" do
      referral!
      now = Time.current
      expect(Psychosocial::Anonymize.patients!([ patient.id ], now: now)).to eq(1)
      expect(Psychosocial::Anonymize.patients!([ patient.id ], now: now + 1.minute)).to eq(0)
      expect(Psychosocial::Anonymize.patients!([])).to eq(0)
    end
  end

  # O trigger "anonimiza uma vez" (db/city_triggers.sql, bloco do 31).
  describe "guarda do banco" do
    it "encaminhamento: uma anonimização (cifrada a NULL, nada mais); anonimizado, congela; a re-cifra e o received seguem" do
      received = referral!
      received.update!(status: "received", received_at: Time.current)
      expect { CityEncryption.allowing_reencryption { received.encrypt } }.not_to raise_error
      expect(received.reload.reason).to eq(reason)

      referral = referral!
      refused(/anonymization clears the encrypted columns/) { referral.update_columns(anonymized_at: Time.current) }
      refused(/anonymization only clears the encrypted columns/) do
        referral.update_columns(anonymized_at: Time.current, reason: nil, priority: "priority")
      end
      referral.update_columns(anonymized_at: Time.current, reason: nil, updated_at: Time.current)
      refused(/anonymized row never changes/) { referral.update_columns(anonymized_at: 1.minute.from_now) }
      refused(/anonymized row never changes/) { referral.update_columns(status: "received", received_at: Time.current) }
      expect { CityEncryption.allowing_reencryption { referral.reload.encrypt } }.not_to raise_error
      refused { referral.delete }
    end

    it "acolhimento: uma anonimização (notes a NULL, nada mais); anonimizado, congela" do
      reception = reception!
      expect { CityEncryption.allowing_reencryption { reception.encrypt } }.not_to raise_error
      refused(/anonymization clears the encrypted columns/) { reception.update_columns(anonymized_at: Time.current) }
      refused(/anonymization only clears the encrypted columns/) do
        reception.update_columns(anonymized_at: Time.current, notes: nil, outcome: "enrolled")
      end
      reception.update_columns(anonymized_at: Time.current, notes: nil)
      refused(/anonymized row never changes/) { reception.update_columns(anonymized_at: 1.minute.from_now) }
      refused { reception.delete }
    end
  end
end
