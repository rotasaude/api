require "rails_helper"

RSpec.describe Attendances::CheckInByException do
  before { Current.city = TEST_CITY_A }
  after { Current.reset; Rails.cache.clear }

  let(:citizen) { Citizen.create!(cpf: "52998224725", phone: "+5541998765432") }
  let(:stranger) { Citizen.create!(cpf: "11144477735", phone: "+5541911112222") }
  let(:staff) { User.create!(email_address: "atendente@cidade.gov.br", password: "senha-segura-123") }
  let(:unit) { create_unit }

  def call(triage_id:, reason: "cidadão sem celular")
    described_class.call(cpf: "529.982.247-25", triage_id: triage_id, health_unit_id: unit.id, reason: reason, by: staff)
  end

  it "lista só triagens elegíveis do CPF" do
    fresh = completed_web_triage_for(citizen)
    completed_web_triage_for(Citizen.create!(cpf: "52998224725", phone: "+5541933334444"), completed_at: 4.days.ago)
    expect(Attendances::EligibleTriages.call(cpf: citizen.cpf).payload[:triages]).to eq([fresh])
  end

  it "abre com motivo e não valida o cadastro" do
    t = completed_web_triage_for(citizen)
    a = call(triage_id: t.id).payload[:attendance]
    expect(a).to have_attributes(check_in_method: "cpf_exception", exception_reason: "cidadão sem celular")
    expect(citizen.reload).to be_verification_level_declared
  end

  it "motivo curto" do
    t = completed_web_triage_for(citizen)
    expect(call(triage_id: t.id, reason: "curto").reason).to eq(:reason_too_short)
  end

  it "triagem de outro CPF: triage_not_eligible, nada criado" do
    other = completed_web_triage_for(stranger)
    expect(call(triage_id: other.id).reason).to eq(:triage_not_eligible)
    expect(Attendance.count).to eq(0)
  end

  it "triagem fora da janela (mais de 3 dias) pelo triage_id direto: triage_not_eligible, nada criado" do
    old = completed_web_triage_for(citizen, completed_at: 3.days.ago - 1.minute)
    expect(call(triage_id: old.id).reason).to eq(:triage_not_eligible)
    expect(Attendance.count).to eq(0)
    expect(DomainEvent.where(name: "attendance.checked_in")).to be_empty
  end

  it "triagem já atendida pelo triage_id direto: triage_not_eligible, nenhum segundo atendimento" do
    t = completed_web_triage_for(citizen)
    first = call(triage_id: t.id).payload.fetch(:attendance)
    expect(call(triage_id: t.id, reason: "segunda tentativa de exceção").reason).to eq(:triage_not_eligible)
    expect(Attendance.pluck(:id)).to eq([ first.id ])
  end

  it "unidade inativa: invalid_unit, nada criado" do
    t = completed_web_triage_for(citizen)
    unit.update!(active: false)
    expect(call(triage_id: t.id).reason).to eq(:invalid_unit)
    expect(Attendance.count).to eq(0)
  end

  it "unidade desativada depois da leitura: invalid_unit, nada criado" do
    t = completed_web_triage_for(citizen)
    deactivate_before_transaction(unit)
    expect(call(triage_id: t.id).reason).to eq(:invalid_unit)
    expect(Attendance.count).to eq(0)
  end

  describe "corrida no INSERT: responde como o caminho do código (already_checked_in com unidade e hora)" do
    let(:other_unit) { create_unit("UPA Norte", kind: "upa") }

    it "triagem: outro check-in commitou entre a busca e o INSERT" do
      t = completed_web_triage_for(citizen)
      earlier = Attendance.create!(triage: t, citizen: citizen, health_unit: other_unit, checked_in_by_user: staff,
                                   checked_in_at: 2.minutes.ago, check_in_method: "code")
      # A busca sem lock ainda não via o atendimento da outra recepção.
      allow(Attendances::CheckInEligibility).to receive(:eligible_for).and_return(Triage.where(id: t.id))

      result = call(triage_id: t.id)
      expect(result.reason).to eq(:already_checked_in)
      expect(result.details).to eq(unit_name: other_unit.name, checked_in_at: earlier.reload.checked_in_at)
      expect(Attendance.count).to eq(1)
    end

    it "horário: outro check-in commitou entre a checagem e o INSERT" do
      doctor = staff_with("medica@cidade.gov.br", "health_professional")
      link_professional!(doctor, unit)
      first = in_care!(waiting_attendance(citizen, unit: unit, by: staff), by: doctor)
      req = Attendances::Close.call(attendance: first, outcome: "return", referral_unit_id: nil, referral_note: nil,
                                    by: doctor).payload.fetch(:appointment_request)
      appt = Appointments::Schedule.call(request: req, scheduled_at: 1.hour.from_now.iso8601, health_unit_id: unit.id,
                                         by: staff).payload.fetch(:appointment)
      reason = "cidadão sem celular"
      earlier = described_class.call(cpf: citizen.cpf, appointment_id: appt.id, health_unit_id: unit.id, reason: reason,
                                     by: staff).payload.fetch(:attendance)
      allow(Attendances::AppointmentCheckInEligibility).to receive(:check).and_return(:ok)

      result = described_class.call(cpf: citizen.cpf, appointment_id: appt.id, health_unit_id: unit.id, reason: reason,
                                    by: staff)
      expect(result.reason).to eq(:already_checked_in)
      expect(result.details).to eq(unit_name: unit.name, checked_in_at: earlier.reload.checked_in_at)
      expect(Attendance.where(appointment_id: appt.id).count).to eq(1)
    end

    it "outra violação de unicidade não vira already_checked_in" do
      t = completed_web_triage_for(citizen)
      allow(Attendance).to receive(:create!)
        .and_raise(ActiveRecord::RecordNotUnique, 'PG::UniqueViolation: ERROR:  duplicate key value violates unique constraint "idx_qualquer_outro"')

      expect { call(triage_id: t.id) }.to raise_error(ActiveRecord::RecordNotUnique, /idx_qualquer_outro/)
    end
  end

  it "não cria atendimento se a triagem foi anonimizada entre a leitura e o lock (ADR 0026)" do
    t = completed_web_triage_for(citizen)
    allow(ApplicationRecord).to receive(:transaction).and_wrap_original do |original, *args, **kwargs, &block|
      t.update_columns(anonymized_at: Time.current)
      original.call(*args, **kwargs, &block)
    end
    expect(call(triage_id: t.id).reason).to eq(:triage_not_eligible)
    expect(Attendance.where(triage_id: t.id)).to be_empty
  end
end
