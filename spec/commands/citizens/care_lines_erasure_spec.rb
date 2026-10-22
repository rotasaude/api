require "rails_helper"

# ADR 0040 (spec §7): condição declarada é apagada e não retém; inscrição e
# contatos retêm. Review Focus 5.
RSpec.describe "Exclusão LGPD — linhas de cuidado" do
  before { care_city! }

  let(:unit) { care_unit! }
  let(:doctor) { care_doctor!(unit) }
  let!(:team) { care_team!(unit, doctor) }

  it "condição declarada não retém; a confirmação apaga declarações e sugestões do par" do
    citizen = care_citizen!(age: 40, sex: "female", neighborhood: care_neighborhood!(unit))
    CareLines::DeclareCondition.call(citizen: citizen, condition: "diabetes")
    CareLineSuggestion.create!(care_line: adopted_line!("diabetes_c4"), team: team, citizen: citizen, reason: "declared")
    request = Citizens::RequestErasure.call(cpf: citizen.cpf, document_checked: true, by: verifier!).payload[:request]
    expect(request.status).to eq("pending")
    expect(Citizens::Erase.call(request: request, by: care_admin!).payload[:request].status).to eq("confirmed")
    expect(CitizenDeclaredCondition.where(citizen_id: citizen.id)).not_to exist
    expect(CareLineSuggestion.where(citizen_id: citizen.id)).not_to exist
  end

  it "inscrição (e contato) retém o pedido; nada se apaga" do
    citizen = care_citizen!(age: 72, sex: "female")
    suggestion = CareLineSuggestion.create!(care_line: adopted_line!("elderly_c6"), team: team, citizen: citizen, reason: "age_sex")
    enrollment = CareLines::AcceptSuggestion.call(suggestion: suggestion, team: team, by: doctor).payload[:enrollment]
    CareLines::RecordContact.call(enrollment: enrollment, channel: "phone", outcome: "reached", note: "Ok", by: doctor)
    CareLines::DeclareCondition.call(citizen: citizen.reload, condition: "hypertension")
    request = Citizens::RequestErasure.call(cpf: citizen.cpf, document_checked: true, by: verifier!).payload[:request]
    expect(request.status).to eq("retained")
    expect(CareLineEnrollment.exists?(enrollment.id)).to be(true)
    expect(CareOutreachContact.where(enrollment_id: enrollment.id).count).to eq(1)
  end

  it "inscrição ENCERRADA (óbito) ainda retém o pedido" do
    citizen = care_citizen!(age: 72, sex: "female")
    suggestion = CareLineSuggestion.create!(care_line: adopted_line!("elderly_c6"), team: team, citizen: citizen, reason: "age_sex")
    enrollment = CareLines::AcceptSuggestion.call(suggestion: suggestion, team: team, by: doctor).payload[:enrollment]
    expect(CareLines::EndEnrollment.call(enrollment: enrollment, reason: "death", note: nil, by: doctor)).to be_ok
    expect(enrollment.reload.status).to eq("ended")
    request = Citizens::RequestErasure.call(cpf: citizen.cpf, document_checked: true, by: verifier!).payload[:request]
    expect(request.status).to eq("retained")
  end

  # A reconferência do Erase usa a mesma regra: inscrição chegada depois do
  # pedido vira `retained` e nada se apaga.
  it "inscrição chegada depois do pedido retém na confirmação" do
    citizen = care_citizen!(age: 72, sex: "female")
    request = Citizens::RequestErasure.call(cpf: citizen.cpf, document_checked: true, by: verifier!).payload[:request]
    expect(request.status).to eq("pending")
    suggestion = CareLineSuggestion.create!(care_line: adopted_line!("elderly_c6"), team: team, citizen: citizen, reason: "age_sex")
    expect(CareLines::AcceptSuggestion.call(suggestion: suggestion, team: team, by: doctor)).to be_ok
    CareLines::DeclareCondition.call(citizen: citizen.reload, condition: "hypertension")
    result = Citizens::Erase.call(request: request, by: care_admin!)
    expect(result.payload[:request].status).to eq("retained")
    expect(CareLineSuggestion.where(id: suggestion.id)).to exist
    expect(CitizenDeclaredCondition.where(citizen_id: citizen.id)).to exist
    expect(citizen.reload.erased_at).to be_nil
  end

  it "o paciente não retido perde as sugestões dele, pendentes e decididas" do
    patient = care_patient!(age: 72, sex: "female")
    citizen = Citizen.find_by!(patient_id: patient.id)
    line = adopted_line!("elderly_c6")
    CareLineSuggestion.create!(care_line: line, team: team, patient: patient, reason: "age_sex")
    CareLineSuggestion.create!(care_line: line, team: team, patient: patient, reason: "age_sex", status: "dismissed",
                               decided_by_user: doctor, decided_at: Time.current, dismiss_reason: "Acompanha na rede privada")
    request = Citizens::RequestErasure.call(cpf: citizen.cpf, document_checked: true, by: verifier!).payload[:request]
    expect(request.status).to eq("pending")
    expect(Citizens::Erase.call(request: request, by: care_admin!).payload[:request].status).to eq("confirmed")
    expect(CareLineSuggestion.where(patient_id: patient.id)).not_to exist
  end

  # Errata (OBRIGATÓRIO): par apagado ou rebaixado do mesmo CPF nunca tem
  # sugestão decidida nem pesa no aceite.
  it "o aceite não decide a sugestão de par do mesmo CPF apagado ou rebaixado; a do par apagado é recusada" do
    line = adopted_line!("elderly_c6")
    first = care_citizen!(age: 72, sex: "female")
    erased = care_citizen!(age: 72, sex: "female")
    downgraded = care_citizen!(age: 72, sex: "female")
    [ erased, downgraded ].each { |pair| pair.update!(cpf: first.cpf) }
    mine, of_erased, of_downgraded = [ first, erased, downgraded ].map do |pair|
      CareLineSuggestion.create!(care_line: line, team: team, citizen: pair, reason: "age_sex")
    end
    erased.update_columns(erased_at: Time.current)
    downgraded.update_columns(verification_level: "declared")

    patients = Patient.count
    refused = CareLines::AcceptSuggestion.call(suggestion: of_erased, team: team, by: doctor)
    expect(refused.reason).to eq(:citizen_not_verified)
    expect(Patient.count).to eq(patients)
    expect(erased.reload.patient_id).to be_nil
    expect(CareLineEnrollment.count).to eq(0)

    accepted = CareLines::AcceptSuggestion.call(suggestion: mine, team: team, by: doctor)
    expect(accepted.payload[:enrollment]).to have_attributes(suggestion_id: mine.id)
    expect([ of_erased, of_downgraded ].map { |s| s.reload.status }).to eq(%w[pending pending])
  end

  # Errata (Task 11 minor): a recusa barata acha o paciente pelo CPF do par
  # não ligado e não liga o par antes de recusar.
  it "par sem paciente de CPF já inscrito: already_enrolled sem ligar o par" do
    line = adopted_line!("elderly_c6")
    patient = care_patient!(age: 72, sex: "female")
    care_enrollment!(patient: patient, line: line, team: team, by: doctor)
    pair = care_citizen!(age: 72, sex: "female")
    pair.update!(cpf: patient.cpf)
    suggestion = CareLineSuggestion.create!(care_line: line, team: team, citizen: pair, reason: "age_sex")
    expect(CareLines::AcceptSuggestion.call(suggestion: suggestion, team: team, by: doctor).reason).to eq(:already_enrolled)
    expect(pair.reload.patient_id).to be_nil
    expect(suggestion.reload).to be_pending
  end

  # M4: o ramo dos pares LIGADOS por patient_id também filtra. A exclusão real
  # troca o CPF pela lápide e mantém o patient_id; o novo par do mesmo CPF
  # aceita e não decide a sugestão que sobrou do par apagado.
  it "o aceite não decide a sugestão de par LIGADO ao paciente e depois apagado (CPF já é lápide)" do
    line = adopted_line!("elderly_c6")
    patient = care_patient!(age: 72, sex: "female")
    old_pair = Citizen.find_by!(patient_id: patient.id)
    cpf = old_pair.cpf
    leftover = CareLineSuggestion.create!(care_line: line, team: team, citizen: old_pair, reason: "age_sex")
    old_pair.update_columns(cpf: Citizens::Erase.tombstone, erased_at: Time.current)
    new_pair = care_citizen!(age: 72, sex: "female")
    new_pair.update!(cpf: cpf)
    mine = CareLineSuggestion.create!(care_line: line, team: team, citizen: new_pair, reason: "age_sex")
    accepted = CareLines::AcceptSuggestion.call(suggestion: mine, team: team, by: doctor)
    expect(accepted.payload[:enrollment]).to have_attributes(patient_id: patient.id, suggestion_id: mine.id)
    expect(leftover.reload).to be_pending
  end

  # I1: o par apagado (ou rebaixado) depois de carregado não declara nem retira.
  it "par apagado ou rebaixado depois de carregado não declara nem retira: not_found, sem linha nem evento" do
    citizen = care_citizen!(age: 40, sex: "female")
    stale = Citizen.find(citizen.id)
    Citizen.where(id: citizen.id).update_all(erased_at: Time.current)
    expect(CareLines::DeclareCondition.call(citizen: stale, condition: "diabetes").reason).to eq(:not_found)
    expect(CitizenDeclaredCondition.where(citizen_id: citizen.id)).not_to exist
    expect(DomainEvent.where(name: "citizen_condition.declared")).not_to exist

    other = care_citizen!(age: 40, sex: "female")
    expect(CareLines::DeclareCondition.call(citizen: other, condition: "diabetes")).to be_ok
    stale = Citizen.find(other.id)
    Citizen.where(id: other.id).update_all(verification_level: "declared")
    expect(CareLines::DeclareCondition.call(citizen: stale, condition: "hypertension").reason).to eq(:not_found)
    expect(CareLines::WithdrawCondition.call(citizen: Citizen.find(other.id), condition: "diabetes").reason).to eq(:not_found)
    expect(CitizenDeclaredCondition.where(citizen_id: other.id).pluck(:withdrawn_at)).to eq([ nil ])
    expect(DomainEvent.where(name: "citizen_condition.withdrawn")).not_to exist
  end

  # I2: o par apagado entre a leitura dos fatos e o INSERT não recebe sugestão.
  it "par apagado depois da leitura dos fatos não recebe sugestão" do
    adopted_line!("elderly_c6")
    neighborhood = care_neighborhood!(unit)
    control = care_citizen!(age: 72, sex: "female", neighborhood: neighborhood)
    expect(CareLines::Suggest.for_citizen(control.id)).to eq(1)

    citizen = care_citizen!(age: 72, sex: "female", neighborhood: neighborhood)
    allow(CareLines::Facts).to receive(:citizens).and_wrap_original do |original, *args|
      original.call(*args).tap { Citizen.where(id: citizen.id).update_all(erased_at: Time.current) }
    end
    queries = []
    callback = ->(*, payload) { queries << payload[:sql] }
    count = ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { CareLines::Suggest.for_citizen(citizen.id) }
    expect(count).to eq(0)
    expect(CareLineSuggestion.where(citizen_id: citizen.id)).not_to exist
    expect(queries.grep(/FROM "citizens".*FOR KEY SHARE/m)).not_to be_empty
  end
end
