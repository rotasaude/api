# spec/commands/consultations/start_spec.rb
require "rails_helper"

# ADR 0031 (spec §4): interruptor utilizável; atendimento in_care chamado por
# quem inicia; CBO permitido; par validado; paciente resolvido; uma por
# atendimento.
RSpec.describe Consultations::Start do
  before { Current.city = clinical_city!; ciap2_release! }
  after { Current.reset }

  let(:unit) { create_unit }
  let(:doctor) { doctor!(unit) }
  let(:citizen) { verified_citizen!(1) }
  let(:attendance) { consulting_attendance!(unit, citizen: citizen, doctor: doctor) }

  it "inicia o rascunho do autor, com vínculo, CBO e tipo sugerido; o paciente nasce; evento só com ids" do
    result = described_class.call(attendance: attendance, by: doctor)
    expect(result).to be_ok
    consultation = result.payload[:consultation]
    link = doctor.professional.links.active.sole
    expect(consultation).to have_attributes(status: "draft", author_user_id: doctor.id, professional_link_id: link.id,
                                            cbo_code: "225125", care_type: 5, attendance_id: attendance.id)
    expect(consultation.patient.cpf).to eq(citizen.cpf)
    expect(citizen.reload.patient_id).to eq(consultation.patient_id)
    expect(DomainEvent.where(name: "consultation.started").sole.payload)
      .to eq("consultation_id" => consultation.id, "attendance_id" => attendance.id)
  end

  it "de novo → already_exists com o id; atendimento com horário sugere consulta agendada" do
    first = described_class.call(attendance: attendance, by: doctor).payload[:consultation]
    again = described_class.call(attendance: attendance, by: doctor)
    expect([ again.reason, again.details ]).to eq([ :already_exists, { consultation_id: first.id } ])
    scheduled = in_care!(scheduled_attendance!(unit, citizen: verified_citizen!(2)), by: doctor)
    expect(described_class.call(attendance: scheduled, by: doctor).payload[:consultation].care_type).to eq(2)
  end

  it "interruptor desligado ou modo diferente de record → feature_disabled" do
    clinical_city!(enabled: false)
    expect(described_class.call(attendance: attendance, by: doctor).reason).to eq(:feature_disabled)
    clinical_city!(record_mode: "integrated")
    expect(described_class.call(attendance: attendance, by: doctor).reason).to eq(:feature_disabled)
    expect(Consultation.count).to eq(0)
  end

  it "par não validado → citizen_not_verified; nada nasce" do
    declared = consulting_attendance!(unit, citizen: screening_citizen!(3), doctor: doctor)
    expect(described_class.call(attendance: declared, by: doctor).reason).to eq(:citizen_not_verified)
    expect([ Consultation.count, Patient.count ]).to eq([ 0, 0 ])
  end

  it "atendimento aguardando, chamado por outra pessoa, papel, vínculo e CBO" do
    waiting = walk_in_attendance!(unit, citizen: verified_citizen!(4))
    expect(described_class.call(attendance: waiting, by: doctor).reason).to eq(:not_in_care)
    colleague = doctor!(unit, cbo: "223505")
    expect(described_class.call(attendance: attendance, by: colleague).reason).to eq(:not_caller)
    expect(described_class.call(attendance: attendance, by: reception!).reason).to eq(:missing_role)
    expect(described_class.call(attendance: attendance, by: doctor!(create_unit("UBS Outra"))).reason).to eq(:missing_link)
    technician = doctor!(unit, cbo: "322205")
    in_care_by_tech = consulting_attendance!(unit, citizen: verified_citizen!(5), doctor: technician)
    expect(described_class.call(attendance: in_care_by_tech, by: technician).reason).to eq(:cbo_not_allowed)
  end
end
