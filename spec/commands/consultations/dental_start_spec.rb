require "rails_helper"

# Módulo 28 (ADR 0046; Desvios 1, 2, 10, 14): iniciar a consulta odontológica.
# Dentista e TSB/ASB iniciam `dental`; só o dentista faz o registro inicial
# (`baseline`, sem tipo de atendimento); gestante pela linha pregnancy_c3;
# interruptor dental_care desligado → feature_disabled com a chave.
RSpec.describe Consultations::Start do
  before { Current.city = dental_city! }
  after { Current.reset }

  let(:unit) { create_unit }
  let(:dentist) { dentist!(unit) }
  let(:citizen) { verified_citizen!(1) }

  def start(by, citizen: self.citizen, **opts)
    attendance = consulting_attendance!(unit, citizen: citizen, doctor: by)
    described_class.call(attendance: attendance, by: by, **opts)
  end

  it "dentista inicia dental: kind, baseline falso, demanda espontânea, CBO do vínculo; evento só com ids" do
    result = start(dentist, kind: "dental")
    expect(result).to be_ok
    consultation = result.payload[:consultation]
    expect(consultation).to have_attributes(kind: "dental", baseline: false, care_type: 5, cbo_code: "223208", status: "draft")
    expect(DomainEvent.where(name: "consultation.started").sole.payload)
      .to eq("consultation_id" => consultation.id, "attendance_id" => consultation.attendance_id)
  end

  it "o TSB/ASB inicia dental; sem kind continua general (contrato antigo)" do
    expect(start(auxiliary!(unit), kind: "dental").payload[:consultation]).to have_attributes(kind: "dental", cbo_code: "322430")
    expect(start(doctor!(unit), citizen: verified_citizen!(2)).payload[:consultation]).to have_attributes(kind: "general", baseline: false)
  end

  it "general pelo dentista e dental pelo médico → cbo_not_allowed; nada nasce" do
    expect(start(dentist, kind: "general").reason).to eq(:cbo_not_allowed)
    expect(start(doctor!(unit), citizen: verified_citizen!(2), kind: "dental").reason).to eq(:cbo_not_allowed)
    expect(Consultation.count).to eq(0)
  end

  it "registro inicial: ASB ou consulta geral → baseline_requires_dentist; o do dentista sem tipo de atendimento" do
    expect(start(auxiliary!(unit), kind: "dental", baseline: true).reason).to eq(:baseline_requires_dentist)
    expect(start(doctor!(unit), citizen: verified_citizen!(2), kind: "general", baseline: true).reason).to eq(:baseline_requires_dentist)
    expect(Consultation.count).to eq(0)
    baseline = start(dentist, citizen: verified_citizen!(3), kind: "dental", baseline: true).payload[:consultation]
    expect(baseline).to have_attributes(kind: "dental", baseline: true, care_type: nil)
  end

  it "vínculo de ASB mais antigo e de dentista na mesma unidade: o registro inicial usa o de dentista" do
    user = auxiliary!(unit)
    link_professional!(user, unit, cbo: "223212")
    consultation = start(user, kind: "dental", baseline: true).payload[:consultation]
    expect(consultation.cbo_code).to eq("223212")
  end

  it "tipo inválido ou baseline que não é booleano → invalid_request com o path" do
    expect([ start(dentist, kind: "xyz").reason, start(dentist, kind: "xyz").details ]).to eq([ :invalid_request, { path: "kind" } ])
    expect(start(dentist, kind: "dental", baseline: "sim").details).to eq(path: "baseline")
  end

  it "gestante com inscrição ativa na linha pregnancy_c3 → pregnant true; sem inscrição → nulo" do
    patient = Patients::Resolve.call(citizen).payload.fetch(:patient)
    line = adopted_line!("pregnancy_c3")
    team = HealthTeam.create!(health_unit: unit, ine: "0000000070", kind: "70", name: "ESF Centro")
    care_enrollment!(patient: patient, line: line, team: team, by: dentist)
    expect(start(dentist, kind: "dental").payload[:consultation].pregnant).to be(true)
    expect(start(dentist, citizen: verified_citizen!(2), kind: "dental").payload[:consultation].pregnant).to be_nil
  end

  it "interruptor dental_care desligado → feature_disabled com a chave; a consulta geral segue" do
    dental_city!(enabled: false)
    result = start(dentist, kind: "dental")
    expect([ result.reason, result.details ]).to eq([ :feature_disabled, { feature: "dental_care" } ])
    expect(start(doctor!(unit), citizen: verified_citizen!(2))).to be_ok
  end
end
